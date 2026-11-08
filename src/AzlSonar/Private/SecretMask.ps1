Set-StrictMode -Version Latest

# Masking a secret without keeping it. The domain account's password has to be held as a SecureString to connect, but
# Sonar must be able to mask it in text it stores, serves or records. Keeping the plaintext in Shared.Redact for the life of
# the process would leave it in memory and one careless serialisation away from the page. So a secret is registered as a
# FINGERPRINT: its length, a rolling hash of its characters and a salted SHA-256, computed inside one function scope from the
# SecureString while the characters sit in a buffer that is cleared before the function returns. The mask slides a window of
# that length over a text; only a window whose rolling hash matches is checked against the SHA-256, and a match is replaced.
# A fingerprint cannot give the password back (it can be guessed against offline, like any hash: it is held in memory only and
# never served, recorded or logged).

if (-not ('AzlSonar.SecretMask' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Security.Cryptography;
using System.Text;

namespace AzlSonar
{
    public static class SecretMask
    {
        private const ulong Base = 1099511628211UL;

        private static string Hex(byte[] bytes)
        {
            StringBuilder sb = new StringBuilder(bytes.Length * 2);
            foreach (byte b in bytes) sb.Append(b.ToString("x2"));
            return sb.ToString();
        }

        private static string Digest(char[] chars, int start, int length, byte[] salt)
        {
            char[] window = new char[length];
            Array.Copy(chars, start, window, 0, length);
            byte[] text = Encoding.UTF8.GetBytes(window);
            byte[] all = new byte[salt.Length + text.Length];
            Buffer.BlockCopy(salt, 0, all, 0, salt.Length);
            Buffer.BlockCopy(text, 0, all, salt.Length, text.Length);
            string hex;
            using (SHA256 sha = SHA256.Create()) hex = Hex(sha.ComputeHash(all));
            Array.Clear(window, 0, window.Length);
            Array.Clear(text, 0, text.Length);
            Array.Clear(all, 0, all.Length);
            return hex;
        }

        // The rolling hash and the salted SHA-256 of the first `length` characters of `secret`.
        public static void Fingerprint(char[] secret, int length, byte[] salt, out ulong rolling, out string sha256)
        {
            ulong h = 0;
            for (int i = 0; i < length; i++) h = unchecked(h * Base + secret[i]);
            rolling = h;
            sha256 = Digest(secret, 0, length, salt);
        }

        // text with every window equal to the fingerprinted secret replaced by `replacement`.
        public static string Mask(string text, int length, ulong rolling, byte[] salt, string sha256, string replacement)
        {
            if (string.IsNullOrEmpty(text) || length <= 0 || text.Length < length) return text;
            char[] chars = text.ToCharArray();
            ulong pow = 1;
            for (int i = 0; i < length; i++) pow = unchecked(pow * Base);
            ulong h = 0;
            for (int i = 0; i < length; i++) h = unchecked(h * Base + chars[i]);
            StringBuilder sb = null;
            int last = 0;
            int start = 0;
            while (true)
            {
                if (h == rolling && string.Equals(Digest(chars, start, length, salt), sha256, StringComparison.Ordinal))
                {
                    if (sb == null) sb = new StringBuilder(text.Length);
                    sb.Append(text, last, start - last).Append(replacement);
                    last = start + length;
                    start = last;
                    if (start + length > chars.Length) break;
                    h = 0;
                    for (int i = 0; i < length; i++) h = unchecked(h * Base + chars[start + i]);
                    continue;
                }
                if (start + length >= chars.Length) break;
                h = unchecked(h * Base + chars[start + length] - chars[start] * pow);
                start++;
            }
            Array.Clear(chars, 0, chars.Length);
            if (sb == null) return text;
            sb.Append(text, last, text.Length - last);
            return sb.ToString();
        }
    }
}
'@
}

function New-AzlSonarSecretFingerprint {
    <#
    .SYNOPSIS
        A fingerprint of a secret that Protect-AzlSonarText can mask with, made from a SecureString without keeping the secret.
    .DESCRIPTION
        The characters are copied into one buffer inside this function, fingerprinted (length, rolling hash, SHA-256 with a
        random salt) and cleared before it returns. No plaintext string is built. The result is { Kind = 'fingerprint', Length,
        Rolling, Salt, Sha256 }: it holds no way back to the password and is never serialised.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds an in-memory value only.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][securestring]$Secret, [byte[]]$SaltBytes)

    $length = $Secret.Length
    if ($length -lt 1) { return $null }
    $pointer = [IntPtr]::Zero
    $chars = [char[]]::new($length)
    try {
        $pointer = [System.Runtime.InteropServices.Marshal]::SecureStringToGlobalAllocUnicode($Secret)
        [System.Runtime.InteropServices.Marshal]::Copy($pointer, $chars, 0, $length)
        # A given salt (to compare with a fingerprint already held) or a fresh random one.
        $salt = [byte[]]::new(16)
        if ($PSBoundParameters.ContainsKey('SaltBytes') -and $null -ne $SaltBytes) { $salt = [byte[]]$SaltBytes.Clone() } else { [System.Security.Cryptography.RandomNumberGenerator]::Fill($salt) }
        $rolling = [uint64]0
        $hash = ''
        [AzlSonar.SecretMask]::Fingerprint($chars, $length, $salt, [ref]$rolling, [ref]$hash)
        return [pscustomobject]@{ Kind = 'fingerprint'; Length = $length; Rolling = $rolling; Salt = $salt; Sha256 = $hash }
    }
    finally {
        [array]::Clear($chars, 0, $chars.Length)
        if ($pointer -ne [IntPtr]::Zero) { [System.Runtime.InteropServices.Marshal]::ZeroFreeGlobalAllocUnicode($pointer) }
    }
}

function Test-AzlSonarFingerprint {
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowNull()][object]$Value)
    return ($null -ne $Value -and $Value -isnot [string] -and $null -ne $Value.PSObject.Properties['Kind'] -and [string]$Value.Kind -eq 'fingerprint')
}

function Hide-AzlSonarFingerprint {
    <#
    .SYNOPSIS
        Text with every secret that is registered as a fingerprint replaced by ***.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][AllowEmptyString()][string]$Text, [AllowNull()][AllowEmptyCollection()][object[]]$Fingerprint = @())

    $out = $Text
    foreach ($f in $Fingerprint) {
        if (-not (Test-AzlSonarFingerprint -Value $f) -or [string]::IsNullOrEmpty($out)) { continue }
        $out = [AzlSonar.SecretMask]::Mask($out, [int]$f.Length, [uint64]$f.Rolling, [byte[]]$f.Salt, [string]$f.Sha256, '***')
    }
    return $out
}
