// AzL Sonar: identifier pseudonymiser for publishable recordings (hardening 2610, gap 1).
//
// Compiled once with Add-Type by Publishable.ps1. It is C# because a real recording is 100+ MB of JSON and the same
// detectors run over every string of it; the PowerShell version of this logic needed hours, this needs minutes.
//
// One instance = one recording: the same original value always gets the same token (case-insensitive), names learned
// from the structured parts of the recording and from earlier matches are replaced everywhere, and Find() runs the same
// detectors without changing anything (the verification pass). Token formats are in docs/reference/publishable-recordings.md.

using System;
using System.Collections.Generic;
using System.Globalization;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace AzlSonar
{
    public sealed class Pseudonymizer
    {
        private sealed class Detector
        {
            public string Name;
            public string Quick;
            public Regex Rx;
            public Func<Match, string, bool> Skip;
            public Func<Match, string> Make;
        }

        private const RegexOptions Compiled = RegexOptions.Compiled | RegexOptions.CultureInvariant;
        private const string TldList = "com|net|org|edu|gov|mil|io|us|uk|de|local|lan|corp|internal|intranet|home|localdomain|test|example|invalid|ad|private|cloud|biz|info|co|eu|ca|au|nz|fr|nl|se|dk|ch|be|pl|cz|jp|cn|br|za|ru|dev|online|tech|site|systems|network|group|global|solutions|services|technology|company|digital|email|today|xyz|mobi";

        private static readonly string[] AllowHost = {
            "microsoft.com", "azure.com", "windows.net", "windowsazure.com", "microsoftonline.com", "microsoftonline-p.com", "azure.net",
            "azureedge.net", "office.com", "office365.com", "live.com", "msftconnecttest.com", "msftncsi.com", "windowsupdate.com",
            "digicert.com", "github.com", "githubusercontent.com", "powershellgallery.com", "nuget.org", "python.org", "w3.org",
            "xmlsoap.org", "openssl.org", "mozilla.org", "apache.org", "gnu.org", "nodejs.org", "sectigo.com", "globalsign.com",
            "verisign.com", "letsencrypt.org", "usertrust.com", "amazontrust.com", "entrust.net", "windows.com", "bing.com",
            "google.com", "cloudflare.com", "akamai.net", "azure-api.net", "microsoft.us", "azure.us", "usgovcloudapi.net",
            "visualstudio.com", "vsassets.io", "vo.msecnd.net", "example.com", "example.net", "example.org",
            "example.test", "azurelocal.cloud", "msedge.net", "ubuntu.com", "redhat.com", "pypi.org", "readthedocs.io", "github.io", "sourceforge.net"
        };

        // Service suffixes whose first label names one of the customer's resources.
        private static readonly string[] NamedSuffix = {
            "blob.core.windows.net", "file.core.windows.net", "queue.core.windows.net", "table.core.windows.net", "dfs.core.windows.net",
            "web.core.windows.net", "vault.azure.net", "vaultcore.azure.net", "database.windows.net", "servicebus.windows.net",
            "scm.azurewebsites.net", "azurewebsites.net", "azurecr.io", "cloudapp.azure.com", "cloudapp.net", "trafficmanager.net",
            "ods.opinsights.azure.com", "oms.opinsights.azure.com", "azure-automation.net", "azconfig.io", "search.windows.net",
            "documents.azure.com", "redis.cache.windows.net", "eventgrid.azure.net", "azurefd.net", "azureedge.net"
        };

        private static readonly Regex NamespaceFirst = new Regex(@"^(system|microsoft|windows|azure|newtonsoft|powershell|az|ms|net|dotnet|aspnet|mono)\.", Compiled | RegexOptions.IgnoreCase);
        private static readonly Regex StopTerm = new Regex(@"^(node|cluster|rg|arc|user|host|res|dom|sub|example|test|local|azure|windows|true|false|null|default|admin|administrator|system|unknown|none|localhost|domain|server|workgroup|machine|account|computer|name|value|public|users|guest|builtin|info|error|warning|debug|verbose|success|failed|running|stopped|enabled|disabled|n/a|empty|local system|network service|local service|nt authority|nt service|everyone|not set|notset|root|admin|dc|ou|cn|ad|corp|com|net|org|internal|intranet|home|private|cloud|hci|azl|arm|edge|core|data|file|files|path|temp|logs|log|deployment|validate|validation|deploy|status|state|step|steps|task|tasks|job|jobs)$", Compiled | RegexOptions.IgnoreCase);
        private static readonly Regex TokenShape = new Regex(@"^(?:(?:node|cluster|rg|arc|user|host|res|dom|dc|ou|cn)-\d{2,}(?:\.example\.test)?|sub-\d{4,}|DOM\d{2,})$", Compiled | RegexOptions.IgnoreCase);
        private static readonly Regex UserSkip = new Regex(@"^(public|default|default user|all users|administrator|defaultuser0|defaultaccount|guest|localservice|networkservice|system|system32|%username%|\*|\{.*|<.*|\$.*|%.*|\[.*|trustedinstaller|wdagutilityaccount|user|username|name|\.net v\d.*|classic \.net apppool)$|^user-\d{2,}$", Compiled | RegexOptions.IgnoreCase);
        private static readonly Regex ContextStop = new Regex(@"^(true|false|null|none|unknown|localhost|n/a|na|empty|system|administrator|local|\.|workgroup|nt authority|builtin|<.*|\{.*|\$.*|%.*|\[.*|\*|-|--|password|current|default|name|value|string|string\[\]|not|set|set\)?|the|a|an|is|was|and|or|to|of|in|for|on|at|by|with|from|as|it|that|this|are|has|have|not found|found|failed|error|ok)$|^(node|cluster|rg|arc|user|host|res|dom)-\d{2,}(\.example\.test)?$|^\d+$", Compiled | RegexOptions.IgnoreCase);
        private static readonly Regex KeepResourceType = new Regex(@"^(extensions|deploymentsettings|arcsettings|updatesummaries|updates|updateruns|jobs|operations|securitysettings|osmanagement|operationstatuses|locations|skus|publishers|versions|types|providers|features|defaults|namespaces|deployments|resources|tags)$", Compiled | RegexOptions.IgnoreCase);
        private static readonly Regex GuidRx = new Regex(@"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", Compiled | RegexOptions.IgnoreCase);
        private static readonly Regex GuidToken = new Regex(@"^00000000-0000-0000-0000-\d{12}$", Compiled);
        // Strings that can hold no identifier: a timestamp, a clock time, a number. A dotted run of digits is NOT plain (an IPv4 address is one).
        private static readonly Regex PlainProbe = new Regex(@"^(?:\d{4}-\d\d-\d\d[T ][\d:.]+Z?|[\d,+\- ]{1,24}|\d{1,2}:\d\d(?::\d\d(?:\.\d+)?)?|\d{1,12}\.\d{1,12})$", Compiled);
        private static readonly Regex EscapedProbe = new Regex(@"&#|_x00|\\u00|%", Compiled | RegexOptions.IgnoreCase);
        private static readonly Regex VersionBefore = new Regex(@"version\W*$", Compiled | RegexOptions.IgnoreCase);

        private static readonly Regex[] SecretRx = {
            new Regex(@"(?i)(\b(?:password|passwd|pwd|secret|client_?secret|access_?token|refresh_?token|api_?key|accountkey|sharedaccesskey)\b\s*[=:]\s*)(""[^""]*""|'[^']*'|[^\s;,&]+)", Compiled),
            new Regex(@"(?i)(\bBearer\s+)[A-Za-z0-9\-\._~\+/]+=*", Compiled),
            new Regex(@"(?i)(\b(?:sig|se|skoid|sktid)=)[^&\s""]+", Compiled),
            new Regex(@"(?i)(-(?:Password|AsPlainText\s+-Force)\s+)(""[^""]*""|'[^']*'|\S+)", Compiled)
        };

        private readonly Dictionary<string, string> tokens = new Dictionary<string, string>();
        private readonly Dictionary<string, long> counters = new Dictionary<string, long>();
        private readonly HashSet<string> used = new HashSet<string>();
        private readonly Dictionary<string, string> terms = new Dictionary<string, string>();
        // A hard term is a name the recording itself declares (config, state, tailer, an Azure resource id, -ExtraTerm): it is
        // replaced everywhere, also inside longer words (5+ characters). A soft term was learned from the text around a match
        // (a UNC path, a URL, ComputerName=): it is replaced as a whole word only, and only when it looks like a name (a digit,
        // a hyphen or an underscore in it), so a common word that showed up in such a place is never replaced everywhere.
        private readonly HashSet<string> hardTerms = new HashSet<string>();
        private readonly HashSet<string> netbios = new HashSet<string>();
        private static readonly Regex CommonWord = new Regex(@"^(software|microsoft|windows|system|system32|syswow64|program ?files|programdata|users|temp|tmp|data|logs?|config|configuration|local|network|server|servers|node|nodes|host|hosts|computer|cluster|azure|cloud|nuget|packages?|shares?|content|bin|lib|modules?|scripts?|common|default|current|machine|services?|service|drivers?|parameters?|policies|policy|classes|classesroot|currentversion|run|runonce|setup|install|installer|deployment|deploy|validate|validation|obs|observability|masl?ogs?|cloudcontent|cloud ?deployment|infrastructure|updates?|download|downloads|public|admin|root|user|name|value|path|file|files|folder|directory|domain|workgroup|localhost|unknown|none|null|true|false|http|https|www|api|web|app|apps|core|net|dotnet|framework|powershell|shell|windowspowershell|v1\.0|wbem|wmi|registry|hklm|hkcu|c|d|e)$", Compiled | RegexOptions.IgnoreCase);
        private static readonly Regex NameLike = new Regex(@"[0-9_\-]", Compiled);
        private readonly List<string> domains = new List<string>();
        private readonly Dictionary<string, long> replaced = new Dictionary<string, long>();
        private readonly Dictionary<string, int> distinct = new Dictionary<string, int>();
        private readonly Dictionary<string, string> cache = new Dictionary<string, string>();
        private readonly HashSet<string> clean = new HashSet<string>();
        private readonly Detector[] statics;
        private Detector[] dynamics = new Detector[0];
        private int termVersion;
        private int dynamicVersion = -1;
        private int cacheVersion = -1;

        public Pseudonymizer(string[] extraTerms)
        {
            statics = BuildStatic();
            if (extraTerms != null)
            {
                foreach (string t in extraTerms)
                {
                    if (string.IsNullOrWhiteSpace(t) || t.Trim().Length < 2) continue;
                    string lower = t.Trim().ToLowerInvariant();
                    if (!terms.ContainsKey(lower))
                    {
                        terms[lower] = "res";
                        hardTerms.Add(lower);
                        termVersion++;
                        Pseudo("res", lower);
                    }
                }
            }
        }

        public IDictionary<string, long> Replaced { get { return replaced; } }
        public IDictionary<string, int> Distinct { get { return distinct; } }
        public int TermCount { get { return terms.Count; } }
        public int DomainCount { get { return domains.Count; } }

        public string[] DetectorNames()
        {
            List<string> names = new List<string>();
            foreach (Detector d in statics) if (!names.Contains(d.Name)) names.Add(d.Name);
            foreach (string n in new[] { "fqdn-learned-domain", "fqdn-host-led", "account", "term" }) if (!names.Contains(n)) names.Add(n);
            return names.ToArray();
        }

        // ---------------------------------------------------------------- tokens

        public string Pseudo(string category, string value)
        {
            string key = category + "|" + value.ToLowerInvariant();
            string token;
            if (tokens.TryGetValue(key, out token)) return token;
            do
            {
                long n;
                counters.TryGetValue(category, out n);
                n++;
                counters[category] = n;
                token = Format(category, n);
            } while (used.Contains(token.ToLowerInvariant()));
            tokens[key] = token;
            used.Add(token.ToLowerInvariant());
            int d;
            distinct.TryGetValue(category, out d);
            distinct[category] = d + 1;
            return token;
        }

        private static string Format(string category, long n)
        {
            CultureInfo c = CultureInfo.InvariantCulture;
            switch (category)
            {
                case "guid": return "00000000-0000-0000-0000-" + n.ToString("D12", c);
                case "hex32": return n.ToString("D32", c);
                case "hex16": return n.ToString("D16", c);
                case "hex64": return n.ToString("D64", c);
                case "thumbprint": return n.ToString("D40", c);
                case "sid": return "S-1-5-21-" + (1000000000L + n).ToString(c) + "-" + (2000000000L + n).ToString(c) + "-" + (3000000000L + n).ToString(c);
                case "ipv4":
                    {
                        long i = n - 1;
                        if (i < 254) return "192.0.2." + (i + 1);
                        if (i < 508) return "198.51.100." + (i - 253);
                        if (i < 762) return "203.0.113." + (i - 507);
                        long m = i - 762;
                        return "198.18." + (m / 254) + "." + ((m % 254) + 1);
                    }
                case "ipv6": return "2001:db8::" + n.ToString("x", c);
                case "mac":
                    {
                        long hi = 0x53 + (n - 1) / 256;
                        long lo = (n - 1) % 256;
                        return "00-00-5e-00-" + hi.ToString("x2", c) + "-" + lo.ToString("x2", c);
                    }
                case "sub": return "sub-" + n.ToString("D4", c);
                case "domain": return "dom-" + n.ToString("D2", c) + ".example.test";
                case "nb": return "DOM" + n.ToString("D2", c);
                default: return category + "-" + n.ToString("D2", c);
            }
        }

        // ---------------------------------------------------------------- terms and domains

        public static bool IsTerm(string value)
        {
            if (string.IsNullOrWhiteSpace(value)) return false;
            string v = value.Trim();
            if (v.Length < 3 || v.Length > 120) return false;
            if (Regex.IsMatch(v, @"^[\d.\-:/ ]+$")) return false;
            if (Regex.IsMatch(v, @"[\s""'<>{}\[\]\\*%$]")) return false;
            if (StopTerm.IsMatch(v)) return false;
            if (TokenShape.IsMatch(v)) return false;
            if (GuidToken.IsMatch(v)) return false;
            return true;
        }

        // A name the recording declares (see hardTerms): replaced everywhere.
        public void RegisterTerm(string category, string value)
        {
            RegisterTerm(category, value, true);
        }

        public void RegisterTerm(string category, string value, bool hard)
        {
            if (!IsTerm(value)) return;
            string v = value.Trim();
            string lower = v.ToLowerInvariant();
            if (category == "nb") { if (netbios.Add(lower)) termVersion++; Pseudo(category, v); }
            if (terms.ContainsKey(lower))
            {
                if (hard && hardTerms.Add(lower)) termVersion++;
                return;
            }
            Pseudo(category, v);
            // A soft term that looks like an ordinary word is never replaced on its own (the match around it already was).
            if (!hard && (CommonWord.IsMatch(v) || !NameLike.IsMatch(v))) return;
            if (category == "nb" && !hard) return;
            terms[lower] = category;
            if (hard) hardTerms.Add(lower);
            termVersion++;
        }

        // Learned from the text around a match: a soft term.
        private void Learn(string category, string value) { RegisterTerm(category, value, false); }

        public string DomainToken(string name)
        {
            string lower = name.ToLowerInvariant().TrimEnd('.');
            string[] labels = lower.Split('.');
            if (labels.Length < 2) return name;
            string hostPart = null;
            string[] domainLabels = labels;
            if (labels.Length >= 3)
            {
                hostPart = labels[0];
                domainLabels = new string[labels.Length - 1];
                Array.Copy(labels, 1, domainLabels, 0, domainLabels.Length);
            }
            string domain = string.Join(".", domainLabels);
            string domainToken = Pseudo("domain", domain);
            if (!domains.Contains(domain))
            {
                domains.Add(domain);
                termVersion++;
                List<string> candidates = new List<string> { domainLabels[0] };
                if (domainLabels.Length >= 3) candidates.Add(domainLabels[domainLabels.Length - 2]);
                foreach (string label in candidates)
                {
                    if (IsTerm(label) && !CommonWord.IsMatch(label)) { if (netbios.Add(label)) termVersion++; Pseudo("nb", label); }
                }
            }
            if (hostPart == null) return domainToken;
            string hostToken;
            string cat;
            if (terms.TryGetValue(hostPart, out cat)) hostToken = Pseudo(cat, hostPart);
            else
            {
                Learn("host", hostPart);
                hostToken = Pseudo("host", hostPart);
            }
            return hostToken + "." + domainToken;
        }

        private static bool Allowed(string name)
        {
            string lower = name.ToLowerInvariant().TrimEnd('.');
            if (NamespaceFirst.IsMatch(lower)) return true;
            foreach (string s in AllowHost) if (lower == s || lower.EndsWith("." + s, StringComparison.Ordinal)) return true;
            return false;
        }

        private static string NamedSuffixOf(string name)
        {
            string lower = name.ToLowerInvariant().TrimEnd('.');
            foreach (string s in NamedSuffix) if (lower.EndsWith("." + s, StringComparison.Ordinal)) return s;
            return "";
        }

        private static bool AzureNameSkip(string type, string name)
        {
            return Regex.IsMatch(name, @"^[{<\[$%*]") || string.Equals(name, "default", StringComparison.OrdinalIgnoreCase) ||
                KeepResourceType.IsMatch(type) || TokenShape.IsMatch(name) || GuidToken.IsMatch(name) || GuidRx.IsMatch(name);
        }

        // ---------------------------------------------------------------- structure

        private static readonly Regex[] StructRx = {
            new Regex(@"(^|\.)(cluster|clusterName)$", Compiled), new Regex(@"(^|\.)resourceGroup$", Compiled),
            new Regex(@"(^|\.)nodes\.#\.(name|hostName|computerName|address)$", Compiled), new Regex(@"(^|\.)nodes\.#\.(arcMachineName|edgeMachineName)$", Compiled),
            new Regex(@"(^|\.)tailer\.node$", Compiled), new Regex(@"(^|\.)tailer\.address$", Compiled), new Regex(@"(^|\.)tailer\.credential$", Compiled),
            new Regex(@"(^|\.)(subscriptionName|subscription)$", Compiled)
        };
        private static readonly string[] StructCat = { "cluster", "rg", "node", "arc", "node", "host", "user", "sub" };

        public void RegisterStructure(string path, string value)
        {
            if (string.IsNullOrEmpty(value)) return;
            string category = null;
            for (int i = 0; i < StructRx.Length; i++) if (StructRx[i].IsMatch(path)) { category = StructCat[i]; break; }
            if (category == null) return;
            if (category == "user" && value.Contains("\\"))
            {
                string[] parts = value.Split(new[] { '\\' }, 2);
                RegisterTerm("nb", parts[0]);
                value = parts[1];
            }
            if (Regex.IsMatch(value, @"^[0-9.:]+$")) return;
            if ((category == "host" || category == "node") && value.Contains(".")) { DomainToken(value); return; }
            RegisterTerm(category, value, true);
        }

        private void RegisterStructureNode(JsonNode node, string path)
        {
            if (node == null) return;
            JsonObject o = node as JsonObject;
            if (o != null)
            {
                foreach (KeyValuePair<string, JsonNode> pair in o) RegisterStructureNode(pair.Value, path.Length > 0 ? path + "." + pair.Key : pair.Key);
                return;
            }
            JsonArray a = node as JsonArray;
            if (a != null)
            {
                foreach (JsonNode item in a) RegisterStructureNode(item, path + ".#");
                return;
            }
            JsonValue v = node as JsonValue;
            if (v != null && v.GetValueKind() == JsonValueKind.String) RegisterStructure(path, v.GetValue<string>());
        }

        public void RegisterEvent(JsonObject ev)
        {
            string kind = Str(ev["k"]);
            if (kind == "session")
            {
                RegisterStructureNode(ev["config"], "");
                RegisterTerm("cluster", Str(ev["cluster"]), true);
            }
            else if (kind == "state")
            {
                if (ev["full"] is JsonObject) RegisterStructureNode(ev["full"], "");
                else if (ev["ops"] is JsonArray)
                {
                    foreach (JsonNode op in (JsonArray)ev["ops"])
                    {
                        JsonArray arr = op as JsonArray;
                        if (arr == null || arr.Count < 3 || !(arr[1] is JsonArray)) continue;
                        List<string> segments = new List<string>();
                        foreach (JsonNode seg in (JsonArray)arr[1])
                        {
                            JsonValue sv = seg as JsonValue;
                            if (sv == null) continue;
                            segments.Add(sv.GetValueKind() == JsonValueKind.Number ? "#" : sv.GetValue<string>());
                        }
                        RegisterStructureNode(arr[2], string.Join(".", segments));
                    }
                }
            }
            else if (kind == "tailer") RegisterStructureNode(ev["tailer"], "tailer");
        }

        private static string Str(JsonNode n)
        {
            JsonValue v = n as JsonValue;
            if (v != null && v.GetValueKind() == JsonValueKind.String) return v.GetValue<string>();
            return "";
        }

        // ---------------------------------------------------------------- detectors

        private Detector[] BuildStatic()
        {
            List<Detector> d = new List<Detector>();
            Func<string, Regex> rx = p => new Regex(p, Compiled);

            d.Add(new Detector
            {
                Name = "azure-subscription", Quick = "/subscriptions/",
                Rx = rx(@"(?i)(?<p>/subscriptions/)(?<v>[^/\s""'\\,;)\]?#&]+)"),
                Skip = (m, s) => { string v = m.Groups["v"].Value; return Regex.IsMatch(v, @"^[{<\[$%*]") || GuidToken.IsMatch(v) || Regex.IsMatch(v, @"^sub-\d{4}$") || GuidRx.IsMatch(v); },
                Make = m => m.Groups["p"].Value + Pseudo("sub", m.Groups["v"].Value)
            });
            d.Add(new Detector
            {
                Name = "azure-resource-group", Quick = "/resourcegroups/",
                Rx = rx(@"(?i)(?<p>/resourceGroups/)(?<v>[^/\s""'\\,;)\]?#&]+)"),
                Skip = (m, s) => { string v = m.Groups["v"].Value; return Regex.IsMatch(v, @"^[{<\[$%*]") || Regex.IsMatch(v, @"^rg-\d{2,}$"); },
                Make = m => { string v = m.Groups["v"].Value; RegisterTerm("rg", v, true); return m.Groups["p"].Value + Pseudo("rg", v); }
            });
            d.Add(new Detector
            {
                Name = "azure-resource-name", Quick = "/providers/",
                Rx = rx(@"(?i)(?<p>/providers/[A-Za-z0-9._]+)(?<rest>(?:/[A-Za-z0-9_.\-]+/[^/\s""'\\,;?#)\]]+)+)"),
                Skip = (m, s) =>
                {
                    string[] parts = m.Groups["rest"].Value.Split(new[] { '/' }, StringSplitOptions.RemoveEmptyEntries);
                    for (int i = 0; i + 1 < parts.Length; i += 2) if (!AzureNameSkip(parts[i], parts[i + 1])) return false;
                    return true;
                },
                Make = m =>
                {
                    string[] parts = m.Groups["rest"].Value.Split(new[] { '/' }, StringSplitOptions.RemoveEmptyEntries);
                    StringBuilder sb = new StringBuilder(m.Groups["p"].Value);
                    for (int i = 0; i < parts.Length; i++)
                    {
                        sb.Append('/');
                        if (i % 2 == 0) { sb.Append(parts[i]); continue; }
                        string type = parts[i - 1], name = parts[i];
                        if (AzureNameSkip(type, name)) { sb.Append(name); continue; }
                        string lt = type.ToLowerInvariant();
                        string cat = lt == "clusters" ? "cluster" : (lt == "machines" || lt == "edgemachines" || lt == "edgedevices" || lt == "devices") ? "arc" : "res";
                        RegisterTerm(cat, name, cat != "res");
                        sb.Append(Pseudo(cat, name));
                    }
                    return sb.ToString();
                }
            });
            d.Add(new Detector
            {
                Name = "email", Quick = "@",
                Rx = rx(@"(?<![A-Za-z0-9._%+\-])(?<u>[A-Za-z0-9._%+\-]+)@(?<d>[A-Za-z0-9\-]+(?:\.[A-Za-z0-9\-]+)*)"),
                Skip = (m, s) => { string u = m.Groups["u"].Value; return Regex.IsMatch(u, @"^user-\d{2,}$") || Regex.IsMatch(u, @"^[{<$%]"); },
                Make = m =>
                {
                    string u = m.Groups["u"].Value, dom = m.Groups["d"].Value;
                    string userToken = Pseudo("user", u);
                    Learn("user", u);
                    string domainToken = dom;
                    if (dom.Contains("."))
                    {
                        if (!Allowed(dom) && !dom.EndsWith(".example.test", StringComparison.OrdinalIgnoreCase))
                        {
                            domainToken = DomainToken("x." + dom);
                            domainToken = domainToken.Substring(domainToken.IndexOf('.') + 1);
                        }
                    }
                    else if (IsTerm(dom) && !CommonWord.IsMatch(dom)) { domainToken = Pseudo("host", dom); Learn("host", dom); }
                    return userToken + "@" + domainToken;
                }
            });
            d.Add(new Detector
            {
                Name = "sid", Quick = "S-1-5-21",
                Rx = rx(@"(?<![A-Za-z0-9])S-1-5-21-(?<a>\d+-\d+-\d+)(?<rid>(?:-\d+)*)(?![0-9A-Za-z])"),
                Skip = (m, s) => Regex.IsMatch(m.Groups["a"].Value, @"^1000000\d{3}-2000000\d{3}-3000000\d{3}$"),
                Make = m => Pseudo("sid", m.Groups["a"].Value) + m.Groups["rid"].Value
            });
            d.Add(new Detector
            {
                Name = "guid", Quick = "-",
                Rx = rx(@"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"),
                Skip = (m, s) => GuidToken.IsMatch(m.Value),
                Make = m => Pseudo("guid", m.Value)
            });
            // A GUID the tool that wrote the log half-masked ("d7f0cf39-xxxx-xxxx-xxxx-xxxxxxxxxxxx", "xxxx-xxxx-xxxx-xxxx-0123456789ab"):
            // the hex groups that are left are still part of the identifier.
            d.Add(new Detector
            {
                Name = "guid-partial", Quick = "-",
                Rx = rx(@"(?:[0-9A-Fa-f]{8}|[xX*]{4,8})(?:-(?:[0-9A-Fa-f]{4}|[xX*]{4})){3}-(?:[0-9A-Fa-f]{12}|[xX*]{4,12})"),
                Skip = (m, s) =>
                {
                    if (!Regex.IsMatch(m.Value, "[xX*]")) return true;   // a plain GUID is the guid detector's
                    foreach (string part in m.Value.Split('-'))
                    {
                        if (Regex.IsMatch(part, "^[0-9A-Fa-f]+$") && !Regex.IsMatch(part, "^0+$")) return false;
                    }
                    return true;
                },
                Make = m =>
                {
                    string[] parts = m.Value.Split('-');
                    for (int i = 0; i < parts.Length; i++) if (Regex.IsMatch(parts[i], "^[0-9A-Fa-f]+$")) parts[i] = new string('0', parts[i].Length);
                    return string.Join("-", parts);
                }
            });
            // The same, cut short ("d7f0cf39-xxxx-xxxx-xxx"): the first group is all that is left of the identifier.
            d.Add(new Detector
            {
                Name = "guid-prefix", Quick = "-",
                Rx = rx(@"[0-9A-Fa-f]{8}-[xX*]{3,}(?:-[xX*]{1,12})*"),
                Skip = (m, s) => Regex.IsMatch(m.Value, "^0{8}-"),
                Make = m => "00000000" + m.Value.Substring(8)
            });
            d.Add(new Detector
            {
                Name = "hex-id", Quick = "",
                Rx = rx(@"(?<![0-9A-Za-z])(?:[0-9A-Fa-f]{64}|[0-9A-Fa-f]{40}|[0-9A-Fa-f]{32}|(?=[0-9A-Fa-f]*[0-9])(?=[0-9A-Fa-f]*[A-Fa-f])[0-9A-Fa-f]{16})(?![0-9A-Za-z])"),
                Skip = (m, s) => Regex.IsMatch(m.Value, @"^0{8,}"),
                Make = m => Pseudo(m.Length == 64 ? "hex64" : m.Length == 40 ? "thumbprint" : m.Length == 32 ? "hex32" : "hex16", m.Value)
            });
            d.Add(new Detector
            {
                Name = "mac", Quick = "",
                Rx = rx(@"(?<![0-9A-Fa-f:\-.])(?:[0-9A-Fa-f]{2}(?<sep>[:\-]))(?:[0-9A-Fa-f]{2}\k<sep>){4}[0-9A-Fa-f]{2}(?![0-9A-Fa-f]|[:\-][0-9A-Fa-f])"),
                Skip = (m, s) => Regex.IsMatch(m.Value, @"^00[:\-]00[:\-]5[eE][:\-]00[:\-]"),
                Make = m =>
                {
                    string t = Pseudo("mac", m.Value).Replace("-", m.Groups["sep"].Value);
                    if (Regex.IsMatch(m.Value, "[A-F]") && !Regex.IsMatch(m.Value, "[a-f]")) t = t.ToUpperInvariant();
                    return t;
                }
            });
            d.Add(new Detector
            {
                Name = "mac", Quick = "",
                Rx = rx(@"(?<![0-9A-Fa-f.])[0-9A-Fa-f]{4}\.[0-9A-Fa-f]{4}\.[0-9A-Fa-f]{4}(?![0-9A-Fa-f]|\.[0-9A-Fa-f])"),
                Skip = (m, s) => Regex.IsMatch(m.Value, @"^0000\.5e00\.", RegexOptions.IgnoreCase) || Regex.IsMatch(m.Value, @"^\d{4}\.\d{4}\.\d{4}$"),
                Make = m => { string t = Pseudo("mac", m.Value).Replace("-", ""); return t.Substring(0, 4) + "." + t.Substring(4, 4) + "." + t.Substring(8, 4); }
            });
            d.Add(new Detector
            {
                Name = "mac", Quick = "",
                Rx = rx(@"(?i)(?<p>\b(?:mac ?address|physical ?address|permanent ?address|network ?address|hw ?addr(?:ess)?)\b[""']?\s*[=:]\s*[""']?)(?<v>[0-9A-F]{12})(?![0-9A-Za-z])"),
                Skip = (m, s) => Regex.IsMatch(m.Groups["v"].Value, @"^00005e00", RegexOptions.IgnoreCase) || Regex.IsMatch(m.Groups["v"].Value, @"^(0{12}|[Ff]{12})$"),
                Make = m => m.Groups["p"].Value + Pseudo("mac", m.Groups["v"].Value).Replace("-", "")
            });
            d.Add(new Detector
            {
                Name = "ipv6", Quick = ":",
                Rx = rx(@"(?<![0-9A-Za-z:])(?=[0-9A-Fa-f:]*::|(?:[0-9A-Fa-f]{1,4}:){7})[0-9A-Fa-f:]{2,39}(?:%[0-9A-Za-z]+)?(?![0-9A-Za-z:])"),
                Skip = (m, s) =>
                {
                    string v = m.Value; int i = v.IndexOf('%'); if (i >= 0) v = v.Substring(0, i);
                    IPAddress ip;
                    if (!IPAddress.TryParse(v, out ip) || ip.AddressFamily != AddressFamily.InterNetworkV6) return true;
                    return v == "::" || v == "::1" || v.StartsWith("2001:db8:", StringComparison.OrdinalIgnoreCase);
                },
                Make = m => { string v = m.Value; int i = v.IndexOf('%'); if (i >= 0) v = v.Substring(0, i); return Pseudo("ipv6", v); }
            });
            const string octet = @"(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)";
            d.Add(new Detector
            {
                Name = "ipv4", Quick = ".",
                Rx = rx(@"(?<![0-9.])(?<![vV])" + octet + @"(?:\." + octet + @"){3}(?![0-9]|\.[0-9])"),
                Skip = (m, s) =>
                {
                    string v = m.Value;
                    if (v == "0.0.0.0" || v.StartsWith("127.") || v == "255.255.255.255") return true;
                    if (Regex.IsMatch(v, @"^255\.255\.(255|254|252|248|240|224|192|128|0)\.\d+$") || Regex.IsMatch(v, @"^\d+\.0\.0\.0$")) return true;
                    if (Regex.IsMatch(v, @"^(192\.0\.2\.|198\.51\.100\.|203\.0\.113\.)") || Regex.IsMatch(v, @"^198\.18\.\d+\.\d+$")) return true;
                    if (Regex.IsMatch(v, @"^255\.(255|254|252|248|240|224|192|128|0)\.0\.0$")) return true;
                    if (m.Index >= 7)
                    {
                        string before = s.Substring(Math.Max(0, m.Index - 12), Math.Min(12, m.Index));
                        if (VersionBefore.IsMatch(before)) return true;
                    }
                    return false;
                },
                Make = m => Pseudo("ipv4", m.Value)
            });
            d.Add(new Detector
            {
                Name = "fqdn", Quick = ".",
                Rx = rx(@"(?i)(?<![A-Za-z0-9_@\-])(?:[A-Za-z0-9](?:[A-Za-z0-9_\-]*[A-Za-z0-9])?\.)+(?:" + TldList + @")(?![A-Za-z0-9_\-]|\.[A-Za-z0-9])"),
                Skip = (m, s) => { string n = m.Value; return (Allowed(n) && NamedSuffixOf(n).Length == 0) || Regex.IsMatch(n, @"\.example\.test$|^example\.test$", RegexOptions.IgnoreCase); },
                Make = m =>
                {
                    string n = m.Value.TrimEnd('.');
                    string suffix = NamedSuffixOf(n);
                    if (suffix.Length > 0)
                    {
                        string prefix = n.Substring(0, n.Length - suffix.Length - 1);
                        Learn("res", prefix);
                        return Pseudo("res", prefix) + "." + n.Substring(n.Length - suffix.Length);
                    }
                    return DomainToken(n);
                }
            });
            d.Add(new Detector
            {
                Name = "account", Quick = "\\",
                Rx = rx(@"(?i)(?<![A-Za-z0-9_\\])(?<d>AzureAD|MicrosoftAccount)\\(?<u>[A-Za-z0-9._@\-]+)"),
                Skip = (m, s) => UserSkip.IsMatch(m.Groups["u"].Value),
                Make = m => { string u = m.Groups["u"].Value; Learn("user", u); return m.Groups["d"].Value + "\\" + Pseudo("user", u); }
            });
            // NETBIOS\user written without a key (all-capital domain, the NetBIOS convention): paths such as Cloud\Logs are not capitals.
            d.Add(new Detector
            {
                Name = "netbios-account", Quick = "\\",
                Rx = rx(@"(?<![A-Za-z0-9_\\:/.$%\-])(?<d>[A-Z][A-Z0-9_\-]{1,14})\\(?<u>[A-Za-z][A-Za-z0-9._$\-]{1,63})(?![A-Za-z0-9_$\\])"),
                Skip = (m, s) =>
                {
                    string dom = m.Groups["d"].Value, u = m.Groups["u"].Value;
                    return Regex.IsMatch(dom, @"^(BUILTIN|NT|WORKGROUP|WINDOWS|SYSTEM|SYSTEM32|PROGRAM|USERS|TEMP|DOM\d+|HKLM|HKCU|HKEY_[A-Z_]+|SOFTWARE|MICROSOFT|CLOUD|LOGS|DATA|C|D|E)$") ||
                        UserSkip.IsMatch(u) || CommonWord.IsMatch(u) || ContextStop.IsMatch(u) || Regex.IsMatch(u, @"^\d+$");
                },
                Make = m =>
                {
                    string dom = m.Groups["d"].Value, u = m.Groups["u"].Value;
                    Learn("nb", dom);
                    Learn("user", u);
                    return Pseudo("nb", dom) + "\\" + Pseudo("user", u);
                }
            });
            d.Add(new Detector
            {
                Name = "hardware-id", Quick = "",
                Rx = rx(@"(?i)(?<p>\b(?:serial ?number|serial|service ?tag|asset ?tag|identifying ?number|wwn|bios ?serial|chassis ?serial|smbios ?uuid|system ?uuid|storage ?account ?name|account ?name|vault ?name|key ?vault ?name|workspace ?name|tenant ?name|subscription ?name|organi[sz]ation|company ?name|customer ?name|site ?name)\b[""']?\s*[=:]\s*[""']?)(?<v>[A-Za-z0-9][A-Za-z0-9_\-]{3,60})"),
                Skip = (m, s) => { string v = m.Groups["v"].Value; return ContextStop.IsMatch(v) || CommonWord.IsMatch(v) || Regex.IsMatch(v, @"^res-\d{2,}$") || Regex.IsMatch(v, @"^0+$") || Regex.IsMatch(v, @"^(not|to[ _]be|default|unknown|none$|microsoft$)", RegexOptions.IgnoreCase); },
                Make = m => { string v = m.Groups["v"].Value; Learn("res", v); return m.Groups["p"].Value + Pseudo("res", v); }
            });
            d.Add(new Detector
            {
                Name = "user-profile", Quick = "sers",
                Rx = rx(@"(?i)(?<p>[\\/](?:Users|home)[\\/])(?<v>[^\\/\s""'<>|:*?]+)"),
                Skip = (m, s) => UserSkip.IsMatch(m.Groups["v"].Value) || CommonWord.IsMatch(m.Groups["v"].Value),
                Make = m => { string v = m.Groups["v"].Value; Learn("user", v); return m.Groups["p"].Value + Pseudo("user", v); }
            });
            d.Add(new Detector
            {
                Name = "unc-host", Quick = "\\\\",
                Rx = rx(@"(?<![A-Za-z0-9\\:])(?<p>\\\\)(?<v>[A-Za-z0-9][A-Za-z0-9_\-]*)(?=\\)"),
                Skip = (m, s) => ContextStop.IsMatch(m.Groups["v"].Value) || CommonWord.IsMatch(m.Groups["v"].Value) || Regex.IsMatch(m.Groups["v"].Value, @"^[0-9.]+$"),
                Make = m => { string v = m.Groups["v"].Value; Learn("host", v); return m.Groups["p"].Value + Pseudo("host", v); }
            });
            d.Add(new Detector
            {
                Name = "url-host", Quick = "://",
                Rx = rx(@"(?i)(?<p>\b(?:https?|ftp|wss?|ldaps?|smb|sftp|ssh|rdp)://(?:[^/\s@""']+@)?)(?<v>[A-Za-z][A-Za-z0-9_\-]*)(?=[:/?#\s""'\\]|$)"),
                Skip = (m, s) => ContextStop.IsMatch(m.Groups["v"].Value) || CommonWord.IsMatch(m.Groups["v"].Value) || string.Equals(m.Groups["v"].Value, "localhost", StringComparison.OrdinalIgnoreCase),
                Make = m => { string v = m.Groups["v"].Value; Learn("host", v); return m.Groups["p"].Value + Pseudo("host", v); }
            });
            d.Add(new Detector
            {
                Name = "distinguished-name", Quick = "=",
                Rx = rx(@"(?i)(?<p>\b(?<k>DC|OU|CN|O|L|ST|E|STREET)=)(?<v>[^,;""'\\=<>]+)"),
                Skip = (m, s) =>
                {
                    string v = m.Groups["v"].Value.Trim();
                    return Regex.IsMatch(v, @"^(microsoft.*|windows.*|azure.*|digicert.*|global ?sign.*|sectigo.*|verisign.*|baltimore.*|entrust.*|isrg.*|amazon.*|google.*|us|users|computers|configuration|schema|system|builtin|domain controllers|managed service accounts|program data|foreignsecurityprincipals|keys|infrastructure|lostandfound|ntds quotas|tpm devices|policies|default domain policy|\{.*|<.*|%.*)$", RegexOptions.IgnoreCase) ||
                        Regex.IsMatch(v, @"^(dc|ou|cn|o|l|st|e|street)-\d{2,}$", RegexOptions.IgnoreCase) || Regex.IsMatch(v, @"^[*$]");
                },
                Make = m => m.Groups["p"].Value + Pseudo(m.Groups["k"].Value.ToLowerInvariant(), m.Groups["v"].Value.Trim())
            });
            // Windows event XML: <Computer>name</Computer> and <Data Name='TargetUserName'>jdoe</Data> style values.
            d.Add(new Detector
            {
                Name = "event-xml", Quick = "<",
                Rx = rx(@"(?is)(?<p><Computer>|<Data\s+Name=[""'](?<k>\w*(?:User|Host|Machine|Workstation|Computer)\w*)[""']\s*>)(?<v>[^<]{1,80})(?=<)"),
                Skip = (m, s) =>
                {
                    string v = m.Groups["v"].Value.Trim();
                    return v.Length == 0 || ContextStop.IsMatch(v) || CommonWord.IsMatch(v) || UserSkip.IsMatch(v) || Regex.IsMatch(v, @"^(-|\-|\*|SYSTEM|LOCAL SERVICE|NETWORK SERVICE|ANONYMOUS LOGON|NT AUTHORITY.*|Window Manager.*|Font Driver.*|DWM-\d+|UMFD-\d+)$", RegexOptions.IgnoreCase) || v.EndsWith(".example.test", StringComparison.OrdinalIgnoreCase);
                },
                Make = m =>
                {
                    string raw = m.Groups["v"].Value;
                    string v = raw.Trim();
                    string lead = raw.Substring(0, raw.IndexOf(v, StringComparison.Ordinal));
                    string k = m.Groups["k"].Success ? m.Groups["k"].Value.ToLowerInvariant() : "computer";
                    string cat = Regex.IsMatch(k, "user") ? "user" : "host";
                    string name = v, dom = "";
                    if (v.Contains("\\")) { dom = v.Substring(0, v.IndexOf('\\')); name = v.Substring(v.IndexOf('\\') + 1); }
                    if (cat == "host" && v.Contains(".")) return m.Groups["p"].Value + lead + DomainToken(v);
                    Learn(cat, name);
                    string o = Pseudo(cat, name);
                    if (dom.Length > 0) { Learn("nb", dom); o = Pseudo("nb", dom) + "\\" + o; }
                    return m.Groups["p"].Value + lead + o;
                }
            });
            // Service principal names (HOST/node, TERMSRV/node ...): the part after the slash is a machine name.
            d.Add(new Detector
            {
                Name = "spn", Quick = "/",
                Rx = rx(@"(?<![A-Za-z0-9_\-])(?<p>(?:HOST|HTTP|CIFS|LDAP|MSSQLSvc|TERMSRV|WSMAN|RPCSS|DNS|RestrictedKrbHost)/)(?<v>[A-Za-z0-9][A-Za-z0-9._\-]*)"),
                Skip = (m, s) => { string v = m.Groups["v"].Value; return ContextStop.IsMatch(v) || CommonWord.IsMatch(v) || v.EndsWith(".example.test", StringComparison.OrdinalIgnoreCase) || Regex.IsMatch(v, @"^[0-9.]+$"); },
                Make = m => { string v = m.Groups["v"].Value; if (v.Contains(".")) return m.Groups["p"].Value + DomainToken(v); Learn("host", v); return m.Groups["p"].Value + Pseudo("host", v); }
            });
            // PowerShell -EncodedCommand payloads are base64 of the script text: nothing in them can be checked, so they go.
            d.Add(new Detector
            {
                Name = "encoded-command", Quick = "-e",
                Rx = rx(@"(?i)(?<p>(?<![A-Za-z0-9_])-e(?:nc(?:odedcommand)?|c)\s+)(?<v>[A-Za-z0-9+/]{16,}={0,2})(?![A-Za-z0-9+/=])"),
                Skip = (m, s) => false,
                Make = m => m.Groups["p"].Value + "[encoded command removed]"
            });
            d.Add(new Detector
            {
                Name = "named-host", Quick = "",
                Rx = rx(@"(?i)(?<p>\b(?<k>computer ?name|host ?name|machine ?name|node ?name|server ?name|dns ?host ?name|netbios ?name|domain ?name|user ?name|account ?name|logon ?user|run ?as ?user|logged ?on ?user|target ?server|remote ?computer)\b[""']?\s*[=:]\s*[""']?)(?<v>[A-Za-z0-9][A-Za-z0-9._$\\@\-]{1,62})"),
                Skip = (m, s) => { string v = m.Groups["v"].Value; return ContextStop.IsMatch(v) || CommonWord.IsMatch(v) || Regex.IsMatch(v, @"^\d[\d.]*$") || v.EndsWith(".example.test", StringComparison.OrdinalIgnoreCase) || v.Contains("@") || UserSkip.IsMatch(v); },
                Make = m =>
                {
                    string raw = m.Groups["v"].Value;
                    string v = raw.TrimEnd('.');
                    string tail = raw.Substring(v.Length);
                    string k = m.Groups["k"].Value.ToLowerInvariant();
                    string cat = Regex.IsMatch(k, "user|account|logon") ? "user" : Regex.IsMatch(k, "domain") ? "nb" : "host";
                    string name = v, dom = "";
                    if (v.Contains("\\")) { dom = v.Substring(0, v.IndexOf('\\')); name = v.Substring(v.IndexOf('\\') + 1); }
                    if (v.Contains(".") && cat == "host") return m.Groups["p"].Value + DomainToken(v) + tail;
                    Learn(cat, name);
                    string o = Pseudo(cat, name);
                    if (dom.Length > 0) { Learn("nb", dom); o = Pseudo("nb", dom) + "\\" + o; }
                    return m.Groups["p"].Value + o + tail;
                }
            });
            return d.ToArray();
        }

        private Detector[] BuildDynamic()
        {
            List<Detector> list = new List<Detector>();
            RegexOptions interpreted = RegexOptions.CultureInvariant;
            List<string> keys = new List<string>(terms.Keys);
            keys.Sort((a, b) => b.Length.CompareTo(a.Length));
            if (domains.Count > 0)
            {
                List<string> ds = new List<string>(domains);
                ds.Sort((a, b) => b.Length.CompareTo(a.Length));
                string alt = string.Join("|", ds.ConvertAll(x => Regex.Escape(x)));
                list.Add(new Detector
                {
                    Name = "fqdn-learned-domain", Quick = ".",
                    Rx = new Regex(@"(?i)(?<![A-Za-z0-9_\-])(?:[A-Za-z0-9_\-]+\.)*(?:" + alt + @")(?![A-Za-z0-9_\-]|\.[A-Za-z0-9])", interpreted),
                    Skip = (m, s) => Regex.IsMatch(m.Value, @"\.example\.test$", RegexOptions.IgnoreCase),
                    Make = m => DomainToken(m.Value.TrimEnd('.'))
                });
            }
            List<string> hostTerms = keys.FindAll(k => k.Length >= 3 && (terms[k] == "node" || terms[k] == "arc" || terms[k] == "cluster" || terms[k] == "host"));
            if (hostTerms.Count > 0)
            {
                string alt = string.Join("|", hostTerms.ConvertAll(x => Regex.Escape(x)));
                list.Add(new Detector
                {
                    Name = "fqdn-host-led", Quick = ".",
                    Rx = new Regex(@"(?i)(?<![A-Za-z0-9])(?:" + alt + @")(?:\.[A-Za-z0-9\-]+){2,}(?![A-Za-z0-9_\-]|\.[A-Za-z0-9])", interpreted),
                    Skip = (m, s) => Regex.IsMatch(m.Value, @"\.example\.test$", RegexOptions.IgnoreCase) || Regex.IsMatch(m.Value, @"\.(log|txt|json|xml|ps1|csv|evtx|etl|zip|cab|msi|exe|dll|yml|yaml|bak|old|tmp)$", RegexOptions.IgnoreCase),
                    Make = m => DomainToken(m.Value.TrimEnd('.'))
                });
            }
            List<string> nbTerms = new List<string>(netbios);
            nbTerms.Sort((a, b) => b.Length.CompareTo(a.Length));
            if (nbTerms.Count > 0)
            {
                string alt = string.Join("|", nbTerms.ConvertAll(x => Regex.Escape(x)));
                list.Add(new Detector
                {
                    Name = "account", Quick = "\\",
                    Rx = new Regex(@"(?i)(?<![A-Za-z0-9_\\])(?<d>" + alt + @")\\(?<u>[A-Za-z0-9._$\-]+)", interpreted),
                    Skip = (m, s) => UserSkip.IsMatch(m.Groups["u"].Value),
                    Make = m => { string u = m.Groups["u"].Value; RegisterTerm("user", u); return Pseudo("nb", m.Groups["d"].Value) + "\\" + Pseudo("user", u); }
                });
            }
            if (keys.Count > 0)
            {
                List<string> shortT = keys.FindAll(k => k.Length < 5 || !hardTerms.Contains(k)).ConvertAll(x => Regex.Escape(x));
                List<string> longT = keys.FindAll(k => k.Length >= 5 && hardTerms.Contains(k)).ConvertAll(x => Regex.Escape(x));
                List<string> parts = new List<string>();
                if (shortT.Count > 0) parts.Add(@"(?<![A-Za-z0-9])(?:" + string.Join("|", shortT) + @")(?![A-Za-z0-9])");
                if (longT.Count > 0) parts.Add(@"(?:" + string.Join("|", longT) + ")");
                list.Add(new Detector
                {
                    Name = "term", Quick = "",
                    Rx = new Regex("(?i)" + string.Join("|", parts), interpreted),
                    Skip = (m, s) => false,
                    Make = m =>
                    {
                        string lower = m.Value.ToLowerInvariant();
                        string cat = terms[lower];
                        string t = Pseudo(cat, lower);
                        return t;
                    }
                });
            }
            return list.ToArray();
        }

        private Detector[] Dynamic()
        {
            if (dynamicVersion != termVersion) { dynamics = BuildDynamic(); dynamicVersion = termVersion; }
            return dynamics;
        }

        // ---------------------------------------------------------------- text

        private static string DecodeEscapes(string text)
        {
            string o = text;
            if (o.IndexOf("&#", StringComparison.Ordinal) >= 0)
                o = Regex.Replace(o, @"&#(?:x(?<h>[0-9A-Fa-f]{2})|(?<d>\d{2,3}));", m =>
                {
                    int c = m.Groups["h"].Success ? Convert.ToInt32(m.Groups["h"].Value, 16) : int.Parse(m.Groups["d"].Value, CultureInfo.InvariantCulture);
                    return (c >= 32 && c < 127) ? ((char)c).ToString() : m.Value;
                });
            if (o.IndexOf("_x00", StringComparison.OrdinalIgnoreCase) >= 0)
                o = Regex.Replace(o, @"_x00(?<h>[2-7][0-9A-Fa-f])_", m => ((char)Convert.ToInt32(m.Groups["h"].Value, 16)).ToString());
            if (o.IndexOf("\\u00", StringComparison.OrdinalIgnoreCase) >= 0)
                o = Regex.Replace(o, @"\\u00(?<h>[2-7][0-9A-Fa-f])", m => ((char)Convert.ToInt32(m.Groups["h"].Value, 16)).ToString());
            if (o.IndexOf('%') >= 0)
                o = Regex.Replace(o, @"%(?<h>40|2[Ee]|2[Ff]|5[Cc]|3[Aa]|2[Dd]|5[Ff])", m => ((char)Convert.ToInt32(m.Groups["h"].Value, 16)).ToString());
            return o;
        }

        private string Run(Detector d, string text)
        {
            StringBuilder sb = null;
            int last = 0;
            foreach (Match m in d.Rx.Matches(text))
            {
                if (d.Skip(m, text)) { used.Add(m.Value.ToLowerInvariant()); continue; }
                long c;
                replaced.TryGetValue(d.Name, out c);
                replaced[d.Name] = c + 1;
                string r = d.Make(m);
                if (sb == null) sb = new StringBuilder(text.Length + 32);
                sb.Append(text, last, m.Index - last).Append(r);
                last = m.Index + m.Length;
            }
            if (sb == null) return text;
            sb.Append(text, last, text.Length - last);
            return sb.ToString();
        }

        public string Protect(string text)
        {
            if (string.IsNullOrEmpty(text) || text.Length < 3) return text;
            string o = text;
            if (EscapedProbe.IsMatch(o)) o = DecodeEscapes(o);
            foreach (Detector d in statics)
            {
                if (d.Quick.Length > 0 && o.IndexOf(d.Quick, StringComparison.OrdinalIgnoreCase) < 0) continue;
                if (!d.Rx.IsMatch(o)) continue;
                o = Run(d, o);
            }
            for (int round = 0; round < 3; round++)
            {
                int before = termVersion;
                foreach (Detector d in Dynamic())
                {
                    if (d.Quick.Length > 0 && o.IndexOf(d.Quick, StringComparison.OrdinalIgnoreCase) < 0) continue;
                    if (!d.Rx.IsMatch(o)) continue;
                    o = Run(d, o);
                }
                if (termVersion == before) break;
            }
            return o;
        }

        public static string MaskSecrets(string text)
        {
            if (string.IsNullOrEmpty(text)) return text;
            string o = text;
            foreach (Regex r in SecretRx) o = r.Replace(o, "${1}***");
            return o;
        }

        // Secrets masked, then identifiers replaced; short strings are cached until a term is learned.
        public string ProtectWithSecrets(string text)
        {
            if (text == null || text.Length < 3) return text;
            if (text.Length <= 40 && PlainProbe.IsMatch(text)) return text;
            bool cacheable = text.Length <= 120;
            if (cacheable)
            {
                if (cacheVersion != termVersion) { cache.Clear(); cacheVersion = termVersion; }
                string hit;
                if (cache.TryGetValue(text, out hit)) return hit;
            }
            string result = Protect(MaskSecrets(text));
            if (cacheable && cacheVersion == termVersion) cache[text] = result;
            return result;
        }

        // The categories of the original identifiers still in a string (read-only: learns nothing).
        public string[] Find(string text)
        {
            List<string> found = new List<string>();
            if (string.IsNullOrEmpty(text) || text.Length < 3) return found.ToArray();
            if (text.Length <= 40 && PlainProbe.IsMatch(text)) return found.ToArray();
            bool cacheable = text.Length <= 120;
            if (cacheable && clean.Contains(text)) return found.ToArray();
            List<Detector> all = new List<Detector>(statics);
            all.AddRange(Dynamic());
            foreach (Detector d in all)
            {
                if (d.Quick.Length > 0 && text.IndexOf(d.Quick, StringComparison.OrdinalIgnoreCase) < 0) continue;
                foreach (Match m in d.Rx.Matches(text)) if (!d.Skip(m, text)) found.Add(d.Name);
            }
            if (cacheable && found.Count == 0) clean.Add(text);
            return found.ToArray();
        }

        // ---------------------------------------------------------------- lines

        private static readonly JsonSerializerOptions WriteOptions = new JsonSerializerOptions
        {
            Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
            WriteIndented = false
        };

        private string Transform(string s) { return ProtectWithSecrets(s); }

        private void Walk(JsonNode node, Func<string, string> fn)
        {
            JsonObject o = node as JsonObject;
            if (o != null)
            {
                List<string> keys = new List<string>();
                foreach (KeyValuePair<string, JsonNode> pair in o) keys.Add(pair.Key);
                List<string[]> renames = null;
                foreach (string key in keys)
                {
                    JsonNode child = o[key];
                    string nk = fn(key);
                    if (!string.Equals(nk, key, StringComparison.Ordinal))
                    {
                        if (renames == null) renames = new List<string[]>();
                        renames.Add(new[] { key, nk });
                    }
                    if (child == null) continue;
                    JsonValue v = child as JsonValue;
                    if (v != null)
                    {
                        if (v.GetValueKind() == JsonValueKind.String)
                        {
                            string text = v.GetValue<string>();
                            string nt = fn(text);
                            if (!string.Equals(nt, text, StringComparison.Ordinal)) o[key] = JsonValue.Create(nt);
                        }
                    }
                    else Walk(child, fn);
                }
                if (renames != null)
                {
                    foreach (string[] r in renames)
                    {
                        if (o.ContainsKey(r[1])) throw new InvalidOperationException("Two keys became the same key after pseudonymising; add -ExtraTerm or review the recording.");
                        JsonNode value = o[r[0]];
                        o.Remove(r[0]);
                        o[r[1]] = value;
                    }
                }
                return;
            }
            JsonArray a = node as JsonArray;
            if (a != null)
            {
                for (int i = 0; i < a.Count; i++)
                {
                    JsonNode child = a[i];
                    if (child == null) continue;
                    JsonValue v = child as JsonValue;
                    if (v != null)
                    {
                        if (v.GetValueKind() == JsonValueKind.String)
                        {
                            string text = v.GetValue<string>();
                            string nt = fn(text);
                            if (!string.Equals(nt, text, StringComparison.Ordinal)) a[i] = JsonValue.Create(nt);
                        }
                    }
                    else Walk(child, fn);
                }
            }
        }

        // One recording line in, the publishable line out (null when the line is not a JSON object). learnOnly: run
        // everything (so names are learned) but do not serialise.
        public string ConvertLine(string line, int maxLogTextLength, bool learnOnly)
        {
            return ConvertLine(line, maxLogTextLength, 0, learnOnly);
        }

        // maxInfoLines > 0 thins every log event to at most that many info lines, spread evenly through it; warning and
        // error lines are always kept, and the number of lines left out is added to the event's "lost".
        public string ConvertLine(string line, int maxLogTextLength, int maxInfoLines, bool learnOnly)
        {
            JsonObject node = JsonNode.Parse(line) as JsonObject;
            if (node == null) return null;
            RegisterEvent(node);
            if (maxInfoLines > 0 && Str(node["k"]) == "log" && node["lines"] is JsonArray)
            {
                JsonArray all = (JsonArray)node["lines"];
                int infoCount = 0;
                foreach (JsonNode item in all) { JsonObject l = item as JsonObject; if (l != null && Str(l["level"]) != "warning" && Str(l["level"]) != "error") infoCount++; }
                if (infoCount > maxInfoLines)
                {
                    int stride = (infoCount + maxInfoLines - 1) / maxInfoLines;
                    JsonArray kept = new JsonArray();
                    int seen = 0, dropped = 0;
                    foreach (JsonNode item in all)
                    {
                        JsonObject l = item as JsonObject;
                        bool important = l != null && (Str(l["level"]) == "warning" || Str(l["level"]) == "error");
                        if (l == null || important || seen++ % stride == 0) kept.Add(item.DeepClone());
                        else dropped++;
                    }
                    node["lines"] = kept;
                    long lost = 0;
                    JsonValue lv = node["lost"] as JsonValue;
                    if (lv != null && lv.GetValueKind() == JsonValueKind.Number) lost = lv.GetValue<long>();
                    node["lost"] = JsonValue.Create(lost + dropped);
                }
            }
            if (maxLogTextLength > 0 && Str(node["k"]) == "log" && node["lines"] is JsonArray)
            {
                // Cut first, at a word boundary, then scrub what is left: a cut never leaves half an identifier.
                char[] boundary = { ' ', '\t', ',', ';', '"', '=', '\\', '/' };
                foreach (JsonNode item in (JsonArray)node["lines"])
                {
                    JsonObject l = item as JsonObject;
                    if (l == null) continue;
                    string text = Str(l["text"]);
                    if (text.Length > maxLogTextLength)
                    {
                        int cut = maxLogTextLength;
                        int space = text.LastIndexOfAny(boundary, maxLogTextLength - 1, Math.Min(200, maxLogTextLength));
                        if (space > 0) cut = space + 1;
                        l["text"] = text.Substring(0, cut) + " ...[" + (text.Length - cut) + " more characters left out of this recording]";
                    }
                }
            }
            Walk(node, Transform);
            return learnOnly ? "" : node.ToJsonString(WriteOptions);
        }

        // Verification of one line: counts of surviving originals per category.
        public void FindLine(string line, IDictionary<string, int> counts)
        {
            JsonNode node;
            try { node = JsonNode.Parse(line); } catch (JsonException) { return; }
            if (node == null) return;
            Walk(node, s =>
            {
                foreach (string f in Find(s))
                {
                    int c;
                    counts.TryGetValue(f, out c);
                    counts[f] = c + 1;
                }
                return s;
            });
        }
    }
}
