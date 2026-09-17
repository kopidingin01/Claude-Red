---
name: offensive-web-recon
description: "Active web-server and application enumeration for the discovery phase of an engagement: DNS zone transfer testing, subdomain/virtual-host discovery on shared IPs, full-range Nmap port sweeps to catch applications on non-standard ports, and NSE/HTTP-based fingerprinting to build a complete inventory of what's actually listening. Tools: dnsrecon, Nmap, dig, gobuster/ffuf (vhost mode), httpx, whatweb. Use once you have a target domain/IP range in scope and need to enumerate every application hosted on the webserver(s) before moving to app-layer testing."
---

# Web Server & Application Enumeration

Before you can attack a web application you have to know it exists. Scope documents list a handful of hostnames; real infrastructure usually serves far more — internal-only vhosts sharing an IP with the production site, staging environments on `:8443`, an admin panel on `:9090` that never made it into the asset inventory, or a secondary DNS server still willing to hand you the entire zone with `AXFR`. This skill covers the PTES-style "Discovery" step of finding every application a webserver is actually hosting: DNS zone transfers, virtual-host/subdomain enumeration, non-standard-port application discovery, and fingerprinting what you find.

## Quick Workflow

1. Attempt a DNS zone transfer (AXFR) against every authoritative nameserver for the domain — free full subdomain map if it succeeds.
2. Run standard + brute-force DNS enumeration with `dnsrecon` to build a candidate hostname list, then resolve and dedupe to unique IPs.
3. Run a **full** TCP port sweep (`-p-`) with Nmap against every unique IP — the default top-1000 misses most non-standard web ports.
4. Run service/version detection and HTTP-focused NSE scripts against every open port flagged as HTTP(S), not just 80/443.
5. Brute-force the `Host` header (vhost enumeration) against each IP — DNS-based enumeration misses vhosts that were never published in public DNS.
6. Pull SANs off any TLS certificate you touch — certs frequently leak internal/staging hostnames.
7. Fingerprint every discovered origin (tech stack, title, status code, auth prompt) and consolidate into one inventory table before moving to app-layer testing.

---

## DNS Zone Transfer (AXFR)

A zone transfer (`AXFR`) is meant for primary→secondary nameserver replication, but many DNS servers still answer it for arbitrary clients. If it succeeds, you get the entire zone — every A/AAAA/CNAME/MX/TXT record — in one query, including hosts that were never linked from anywhere public.

```bash
# 1. Enumerate the domain's authoritative nameservers
dnsrecon -d target.com -t std

# 2. dnsrecon automatically tries AXFR against every NS it finds during a standard scan,
#    but you can force it explicitly and target a single NS
dnsrecon -d target.com -t axfr
dnsrecon -d target.com -n ns1.target.com -t axfr

# 3. Cross-check manually with dig — dnsrecon's AXFR parsing can miss edge cases
for ns in $(dig +short NS target.com); do
  echo "== $ns =="
  dig axfr target.com @"$ns"
done

# 4. host(1) works too and is useful when dnsrecon/dig aren't available
host -t axfr target.com ns1.target.com
```

If AXFR is refused (the common case against hardened infrastructure), move straight to active/passive enumeration below — but always try it first, it's a single request with an outsized payoff when it works.

---

## DNS Enumeration & Subdomain Discovery

`dnsrecon` is the workhorse here — it combines standard record enumeration, brute forcing, SRV/TXT harvesting, reverse lookups, and zone walking in one tool.

```bash
# Standard scan: SOA, NS, A, AAAA, MX, TXT, SRV, and an AXFR attempt against each NS
dnsrecon -d target.com -t std

# Brute force subdomains against a wordlist (SecLists' subdomains-top1million-*.txt is a good default)
dnsrecon -d target.com -D /usr/share/seclists/Discovery/DNS/subdomains-top1million-5000.txt -t brt

# Combine record types in one run and write structured output for later diffing
dnsrecon -d target.com -t std,brt,srv,axfr -D subdomains.txt -c results.csv

# Reverse-resolve a discovered CIDR to catch PTR-only hosts
dnsrecon -r 10.10.20.0/24

# Google/Bing-assisted enumeration for indexed hostnames dnsrecon's wordlist won't guess
dnsrecon -d target.com -t goo,bing
```

Pair the brute-force results with passive sources so you're not relying on a single wordlist:

```bash
subfinder -d target.com -silent
amass enum -passive -d target.com

# Certificate Transparency — frequently the fastest way to surface staging/internal names
curl -s "https://crt.sh/?q=%25.target.com&output=json" | jq -r '.[].name_value' | sort -u
```

Merge all sources, strip duplicates, and resolve everything to IPs before the port-scanning stage — you want a clean `hostname -> IP` map, and a clean list of *unique* IPs to actually scan (scanning the same box 40 times under different vhosts wastes time).

```bash
cat dnsrecon-hosts.txt subfinder.txt crtsh.txt | sort -u | dnsx -a -resp -o resolved.txt
awk '{print $2}' resolved.txt | tr -d '[]' | sort -u > unique-ips.txt
```

Don't ignore non-A record types while you're in there:

- **TXT** — SPF includes, domain-verification tokens, and occasionally internal hostnames dropped in during setup and never cleaned up.
- **SRV** — reveals internal service topology (`_ldap._tcp`, `_sip._tls`, autodiscover records) even when no A record is published for the underlying host.
- **CNAME chains** — often point at third-party SaaS (help desks, status pages, marketing tools) that are out of scope but worth noting, and occasionally at a dangling CNAME you can take over.

---

## Full Port Sweep with Nmap

Scanning only 80/443 is the single most common way to miss applications during discovery. Run a full sweep against every unique IP you resolved above before you decide what's "in scope for web testing."

```bash
# Full TCP range, open ports only, reasonable timing for an authorized external engagement
nmap -p- --open -T4 -Pn -oA fullscan_<ip> <ip>

# For large ranges, let masscan do the fast first pass, then hand confirmed-open ports to Nmap for accuracy
masscan -p1-65535 --rate 1000 -oL masscan.out <ip>/24
# ...parse masscan.out into a per-host port list, then:
nmap -sV -sC -p<comma-separated-ports> -oA verify_<ip> <ip>

# Don't skip UDP entirely — DNS (53), SNMP (161), and NTP (123) all show up on webserver hosts
# and are worth a quick top-ports sweep even on an engagement scoped as "web"
nmap -sU --top-ports 50 -oA udp_<ip> <ip>
```

Once you have the open-port list, run service/version detection plus HTTP-specific NSE scripts against every port that responds like HTTP, regardless of number:

```bash
nmap -sV -sC -p<ports> \
  --script=http-title,http-headers,http-methods,http-enum,http-waf-detect,ssl-cert \
  -oA httpenum_<ip> <ip>
```

- `http-title` / `http-headers` — fastest way to eyeball what's actually running on an unfamiliar port.
- `http-enum` — walks a small built-in wordlist of common paths (admin panels, backup files, install scripts).
- `ssl-cert` — dumps certificate SANs; a fast way to pick up additional hostnames on any TLS port, standard or not.
- `http-methods` — flags `PUT`/`DELETE`/`TRACE` enabled, useful context for later.

---

## Virtual Host / Subdomain-on-Shared-IP Discovery

DNS enumeration only finds hostnames that are *published*. Shared hosting and internal load balancers frequently answer for vhosts that were deliberately kept out of public DNS (internal admin panels, pre-release marketing sites, tenant-specific subdomains on a multi-tenant SaaS). Since the webserver still has to route by `Host` header, you can brute-force it directly against the IP.

```bash
# gobuster vhost mode against a bare IP — --append-domain resolves FUZZ.target.com style entries
gobuster vhost -u https://<ip> -k --append-domain \
  -w /usr/share/seclists/Discovery/DNS/subdomains-top1million-5000.txt \
  -d target.com

# ffuf gives finer control over filtering false positives by response size
ffuf -w subdomains.txt -u https://<ip>/ -H "Host: FUZZ.target.com" \
  -fs <baseline-response-size> -mc all -t 50
```

Always establish a baseline first — request a hostname you *know* doesn't exist and note the response size/status/title. Wildcard vhost configs will answer every `Host` header with the same default page, and without a baseline you'll drown in false positives.

```bash
curl -sk -H "Host: definitely-not-a-real-vhost-$RANDOM.target.com" https://<ip>/ -o baseline.html -w "%{size_download} %{http_code}\n"
```

Cross-reference against certificate SANs collected during the Nmap pass — a multi-domain cert is effectively a free vhost list:

```bash
openssl s_client -connect <ip>:443 -servername target.com </dev/null 2>/dev/null \
  | openssl x509 -noout -text | grep -A1 "Subject Alternative Name"
```

---

## Non-Standard Port Application Enumeration

Web applications don't only live on 80/443. Treat the following as a starting checklist, not an exhaustive one — the Nmap full sweep above is what actually catches what a fixed list misses:

| Port | Common use |
|---|---|
| 81, 88, 591, 8000, 8008, 8080, 8081, 8880 | Alternate HTTP, dev servers, proxies |
| 3000, 5000 | Node/Flask/Rails dev servers, often left exposed |
| 3128, 8118 | Proxy/cache servers (Squid, Privoxy) |
| 5601 | Kibana |
| 7001, 7002 | Oracle WebLogic |
| 8443, 9443, 10443 | Alternate HTTPS |
| 8888, 8889 | Jupyter, alternate admin UIs |
| 9000, 9090, 9091 | Portainer, PHP-FPM status, Prometheus/cAdvisor |
| 9200, 9300 | Elasticsearch REST/transport |
| 10000 | Webmin |

Once the full port sweep is done, pull every open port that answers like HTTP(S) — regardless of whether it's "standard" — and fingerprint it in bulk:

```bash
# Feed the resolved-IP list plus the specific open ports found per host into httpx for mass triage
httpx -l unique-ips.txt -p 80,443,8000,8080,8081,8443,8888,9000,9090,9200,10000 \
  -title -status-code -tech-detect -follow-redirects -o httpx-results.txt

# Screenshot everything that responds for fast visual triage across dozens of hosts/ports
eyewitness --web -f httpx-results.txt -d eyewitness-out
```

A port that Nmap fingerprints as a generic `http` service is worth a manual look even if `httpx`/`whatweb` can't identify the stack — misconfigured dev servers, internal dashboards, and abandoned staging apps are exactly what version-detection heuristics miss.

---

## Application Fingerprinting & Inventory

For every origin discovered above (hostname×IP×port combination), capture enough to prioritize app-layer testing later:

```bash
whatweb -a 3 http://<host>:<port>
nmap --script http-enum,http-headers,http-title -p<port> <ip>
```

Build a running inventory rather than testing ad hoc — it's what lets you notice patterns (same CMS across ten subdomains, one outlier running an old framework version) and avoid re-scanning the same app twice under different hostnames:

| Hostname | IP | Port | Scheme | Tech / Server header | Title | Auth prompt? | Notes |
|---|---|---|---|---|---|---|---|
| app.target.com | 10.0.0.5 | 443 | https | nginx / React SPA | "Target — Dashboard" | Yes (SSO) | Primary app |
| stg.target.com | 10.0.0.5 | 8443 | https | Apache/2.4 / PHP 7.2 | "Staging" | No | Not in original scope doc — confirm |
| 10.0.0.5 | 10.0.0.5 | 9090 | http | (no title, generic 401) | — | Basic auth | Found via full port sweep only |

Flag anything that stands out for prioritization: unauthenticated admin panels, default install pages (`It works!`, framework welcome screens), obviously outdated software in the `Server`/`X-Powered-By` headers, and any host present in the port scan but absent from the client's asset inventory — that gap is itself a finding worth reporting.

---

## Detection / Defender View

- **AXFR attempts** are logged by any properly configured DNS server and are a well-known IOC; most modern authoritative DNS restricts transfers to an ACL of known secondary IPs, so a refusal is the expected/normal outcome, not a sign something is broken.
- **Full port sweeps** (`-p-`) generate a large volume of SYN packets from one source and are a textbook IDS/IPS signature. On authorized engagements where stealth isn't a requirement, this is fine; where it matters, throttle with `-T2`/`-T3`, add `--randomize-hosts` for multi-host scans, and consider splitting the range across a longer time window.
- **Vhost brute forcing** produces a burst of requests to one IP with a rapidly changing `Host` header and a high 404/error ratio — WAFs and rate-limiters increasingly flag this pattern specifically (as opposed to path brute forcing, which is more commonly tuned for).
- **Certificate SAN pivoting and passive DNS/CT-log lookups** are invisible to the target entirely — prefer them first when stealth matters, and treat active brute forcing as the fallback once passive sources are exhausted.

---

## Engagement Cheatsheet

```bash
# 1. Zone transfer — always try first, zero cost
for ns in $(dig +short NS target.com); do dig axfr target.com @"$ns"; done

# 2. DNS enumeration (active + passive), merge and resolve
dnsrecon -d target.com -t std,brt,srv -D subdomains.txt -c dnsrecon.csv
subfinder -d target.com -silent >> subs.txt
curl -s "https://crt.sh/?q=%25.target.com&output=json" | jq -r '.[].name_value' >> subs.txt
sort -u subs.txt | dnsx -a -resp -o resolved.txt

# 3. Full port sweep per unique IP
awk '{print $2}' resolved.txt | tr -d '[]' | sort -u | \
  xargs -I{} nmap -p- --open -T4 -Pn -oA fullscan_{} {}

# 4. HTTP fingerprint every open port
nmap -sV -sC -p<ports> --script=http-title,http-headers,http-enum,ssl-cert -oA httpenum_{} {}

# 5. Vhost brute force against each unique IP
ffuf -w subdomains.txt -u https://<ip>/ -H "Host: FUZZ.target.com" -fs <baseline-size>

# 6. Bulk fingerprint + screenshot everything found
httpx -l resolved-ips.txt -p 80,443,8080,8443,8888,9000,9090,9200,10000 -title -status-code -tech-detect
eyewitness --web -f httpx-results.txt -d eyewitness-out
```

---

## Key References

- PTES Technical Guidelines — Intelligence Gathering / Discovery: http://www.pentest-standard.org/index.php/PTES_Technical_Guidelines
- RFC 5936 — DNS Zone Transfer Protocol (AXFR): https://www.rfc-editor.org/rfc/rfc5936
- `dnsrecon` — https://github.com/darkoperator/dnsrecon
- Nmap NSE HTTP scripts — https://nmap.org/nsedoc/categories/discovery.html
- `httpx` (ProjectDiscovery) — https://github.com/projectdiscovery/httpx
- OWASP WSTG — Information Gathering: https://owasp.org/www-project-web-security-testing-guide/
