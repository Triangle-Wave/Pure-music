//! Process-wide proxy configuration shared by every reqwest client.

use std::sync::Mutex;

use reqwest::blocking::ClientBuilder;

/// Generation returned when the settings cannot be read, so callers never
/// mistake the direct fallback for a configured proxy.
const FALLBACK_GENERATION: u64 = u64::MAX;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ProxyMode {
    System,
    Direct,
    Manual,
}

impl ProxyMode {
    fn parse(mode: &str) -> Result<Self, String> {
        match mode.trim().to_ascii_lowercase().as_str() {
            "system" => Ok(Self::System),
            "direct" => Ok(Self::Direct),
            "manual" => Ok(Self::Manual),
            other => Err(format!(
                "unsupported proxy mode '{other}'; expected system, direct or manual"
            )),
        }
    }
}

#[derive(Clone)]
struct ProxySettings {
    generation: u64,
    mode: ProxyMode,
    /// Proxy URL without the port, always carrying an `http` or `https` scheme.
    host: String,
    port: u16,
    username: String,
    password: String,
    /// Comma separated host list that bypasses the manual proxy.
    bypass: String,
}

impl ProxySettings {
    const fn new() -> Self {
        Self {
            generation: 0,
            mode: ProxyMode::System,
            host: String::new(),
            port: 0,
            username: String::new(),
            password: String::new(),
            bypass: String::new(),
        }
    }
}

static PROXY_SETTINGS: Mutex<ProxySettings> = Mutex::new(ProxySettings::new());

impl std::fmt::Debug for ProxySettings {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("ProxySettings")
            .field("generation", &self.generation)
            .field("mode", &self.mode)
            .field("host", &self.host)
            .field("port", &self.port)
            .field("username", &self.username)
            .field("password", &"<redacted>")
            .field("bypass", &self.bypass)
            .finish()
    }
}

/// Updates the process-wide proxy used by all network requests.
///
/// `mode` accepts `system` (reqwest default: environment proxy variables),
/// `direct` (never use a proxy) or `manual` (always use `host:port`).
/// `host` may include an `http://` or `https://` prefix; SOCKS is rejected.
/// `bypass` is a comma separated no-proxy list applied in `manual` mode.
///
/// # Errors
///
/// Returns an error for an unknown mode, a missing host or port in `manual`
/// mode, a non http/https scheme, or a password without a username.
#[flutter_rust_bridge::frb]
pub fn set_network_proxy(
    mode: String,
    host: String,
    port: u16,
    username: String,
    password: String,
    bypass: String,
) -> Result<(), String> {
    let parsed_mode = ProxyMode::parse(&mode)?;
    let mut settings = build_settings(parsed_mode, &host, port, &username, &password, &bypass)?;

    let mut guard = match PROXY_SETTINGS.lock() {
        Ok(guard) => guard,
        Err(poisoned) => {
            log::warn!(
                target: "proxy",
                "proxy settings lock poisoned while writing, recovering: {poisoned}"
            );
            PROXY_SETTINGS.clear_poison();
            poisoned.into_inner()
        }
    };

    let generation = guard.generation.wrapping_add(1);
    settings.generation = generation;
    let mode = settings.mode;
    let host = settings.host.clone();
    let port = settings.port;
    let has_auth = !settings.username.is_empty();
    let has_bypass = !settings.bypass.is_empty();
    *guard = settings;
    drop(guard);

    log::info!(
        target: "proxy",
        "proxy settings updated: mode={:?}, host={}, port={}, auth={}, bypass={}, generation={}",
        mode,
        host,
        port,
        has_auth,
        has_bypass,
        generation
    );

    Ok(())
}

/// Applies the current proxy settings to a client builder.
///
/// Returns the builder together with the generation it was built from, so a
/// caller caching the built client can rebuild when the generation changes.
/// A poisoned lock or an unusable manual configuration falls back to direct.
pub(crate) fn apply_to_builder(builder: ClientBuilder) -> (ClientBuilder, u64) {
    let settings = match PROXY_SETTINGS.lock() {
        Ok(guard) => guard.clone(),
        Err(poisoned) => {
            log::warn!(
                target: "proxy",
                "failed to read proxy settings, falling back to direct: {poisoned}"
            );
            return (builder.no_proxy(), FALLBACK_GENERATION);
        }
    };

    let generation = settings.generation;
    match settings.mode {
        ProxyMode::System => (builder, generation),
        ProxyMode::Direct => (builder.no_proxy(), generation),
        ProxyMode::Manual => match manual_proxy(&settings) {
            Ok(proxy) => (builder.proxy(proxy), generation),
            Err(err) => {
                log::warn!(
                    target: "proxy",
                    "manual proxy unusable, falling back to direct: {err}"
                );
                (builder.no_proxy(), generation)
            }
        },
    }
}

/// Returns the generation of the active configuration without building a client.
pub(crate) fn current_generation() -> u64 {
    match PROXY_SETTINGS.lock() {
        Ok(settings) => settings.generation,
        Err(poisoned) => {
            log::warn!(
                target: "proxy",
                "failed to read proxy generation, falling back to direct: {poisoned}"
            );
            FALLBACK_GENERATION
        }
    }
}

fn build_settings(
    mode: ProxyMode,
    host: &str,
    port: u16,
    username: &str,
    password: &str,
    bypass: &str,
) -> Result<ProxySettings, String> {
    let username = username.trim();
    if mode != ProxyMode::Manual {
        return Ok(ProxySettings {
            mode,
            ..ProxySettings::new()
        });
    }

    let host = normalize_manual_host(host)?;
    if port == 0 {
        return Err("manual proxy requires a port between 1 and 65535".to_string());
    }
    if username.is_empty() && !password.is_empty() {
        return Err("manual proxy password requires a username".to_string());
    }

    Ok(ProxySettings {
        generation: 0,
        mode,
        host,
        port,
        username: username.to_string(),
        password: if username.is_empty() {
            String::new()
        } else {
            password.to_string()
        },
        bypass: bypass.trim().to_string(),
    })
}

fn normalize_manual_host(raw: &str) -> Result<String, String> {
    let host = raw.trim();
    if host.is_empty() {
        return Err("manual proxy requires a host".to_string());
    }

    let lower = host.to_ascii_lowercase();
    const SOCKS_SCHEMES: [&str; 5] = [
        "socks5://",
        "socks5h://",
        "socks4://",
        "socks4a://",
        "socks://",
    ];
    if SOCKS_SCHEMES.iter().any(|scheme| lower.starts_with(*scheme)) {
        return Err("SOCKS proxy is not supported; use an http or https proxy".to_string());
    }

    let (scheme, rest) = match host.split_once("://") {
        Some((scheme, rest)) => (scheme.to_ascii_lowercase(), rest),
        None => ("http".to_string(), host),
    };
    if scheme != "http" && scheme != "https" {
        return Err(format!(
            "unsupported proxy scheme '{scheme}'; only http and https are allowed"
        ));
    }

    let rest = rest.trim_end_matches('/');
    if rest.is_empty() {
        return Err("manual proxy requires a host".to_string());
    }
    if rest.contains(['/', '?', '#', '@']) || rest.chars().any(char::is_whitespace) {
        return Err(
            "proxy host must not contain a path, credentials or whitespace".to_string(),
        );
    }

    let bracketed_ipv6 = rest.starts_with('[') && rest.ends_with(']');
    if rest.contains(':') && !bracketed_ipv6 {
        return Err("proxy host must not contain a port; fill the port separately".to_string());
    }
    if rest.starts_with('[') != rest.ends_with(']') {
        return Err("invalid IPv6 proxy host, expected [address]".to_string());
    }
    if bracketed_ipv6 && rest.len() <= 2 {
        return Err("invalid IPv6 proxy host, expected [address]".to_string());
    }

    Ok(format!("{scheme}://{rest}"))
}

fn manual_proxy(settings: &ProxySettings) -> Result<reqwest::Proxy, String> {
    let url = format!("{}:{}", settings.host, settings.port);
    let proxy = reqwest::Proxy::all(url).map_err(|err| format!("invalid proxy address: {err}"))?;

    let proxy = if settings.bypass.is_empty() {
        proxy
    } else {
        proxy.no_proxy(reqwest::NoProxy::from_string(&settings.bypass))
    };

    if settings.username.is_empty() {
        Ok(proxy)
    } else {
        Ok(proxy.basic_auth(&settings.username, &settings.password))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn manual(host: &str, port: u16) -> Result<ProxySettings, String> {
        build_settings(ProxyMode::Manual, host, port, "", "", "")
    }

    #[test]
    fn parse_mode_accepts_known_values() {
        assert_eq!(ProxyMode::parse("system").unwrap(), ProxyMode::System);
        assert_eq!(ProxyMode::parse(" Direct ").unwrap(), ProxyMode::Direct);
        assert_eq!(ProxyMode::parse("MANUAL").unwrap(), ProxyMode::Manual);
    }

    #[test]
    fn parse_mode_rejects_unknown_value() {
        assert!(ProxyMode::parse("auto").is_err());
        assert!(ProxyMode::parse("").is_err());
    }

    #[test]
    fn default_settings_use_system_mode() {
        let settings = ProxySettings::new();
        assert_eq!(settings.mode, ProxyMode::System);
        assert_eq!(settings.generation, 0);
    }

    #[test]
    fn manual_mode_requires_host() {
        let err = manual("   ", 7890).unwrap_err();
        assert!(err.contains("requires a host"), "unexpected error: {err}");
    }

    #[test]
    fn manual_mode_requires_port() {
        let err = manual("127.0.0.1", 0).unwrap_err();
        assert!(err.contains("port"), "unexpected error: {err}");
    }

    #[test]
    fn manual_mode_rejects_socks_proxy() {
        let hosts = [
            "socks5://127.0.0.1",
            "SOCKS5H://127.0.0.1",
            "socks4://127.0.0.1",
        ];
        for host in hosts {
            let err = manual(host, 1080).unwrap_err();
            assert!(err.contains("SOCKS"), "unexpected error for {host}: {err}");
        }
    }

    #[test]
    fn manual_mode_rejects_other_schemes() {
        let err = manual("ftp://127.0.0.1", 21).unwrap_err();
        assert!(err.contains("unsupported proxy scheme"), "unexpected: {err}");
    }

    #[test]
    fn manual_mode_defaults_to_http_scheme() {
        let settings = manual("127.0.0.1", 7890).unwrap();
        assert_eq!(settings.host, "http://127.0.0.1");
        assert_eq!(settings.port, 7890);
    }

    #[test]
    fn manual_mode_keeps_https_scheme() {
        let settings = manual("https://proxy.local", 8443).unwrap();
        assert_eq!(settings.host, "https://proxy.local");
    }

    #[test]
    fn manual_mode_rejects_host_with_port() {
        let err = manual("127.0.0.1:7890", 7890).unwrap_err();
        assert!(err.contains("fill the port separately"), "unexpected: {err}");
    }

    #[test]
    fn manual_mode_accepts_bracketed_ipv6() {
        let settings = manual("[::1]", 7890).unwrap();
        assert_eq!(settings.host, "http://[::1]");
    }

    #[test]
    fn manual_mode_rejects_password_without_username() {
        let err = build_settings(
            ProxyMode::Manual,
            "proxy.local",
            3128,
            "  ",
            "secret",
            "",
        )
        .unwrap_err();
        assert!(err.contains("requires a username"), "unexpected: {err}");
    }

    #[test]
    fn manual_mode_keeps_credentials_and_bypass() {
        let settings = build_settings(
            ProxyMode::Manual,
            "proxy.local",
            3128,
            "user",
            "secret",
            " localhost, *.corp ",
        )
        .unwrap();
        assert_eq!(settings.username, "user");
        assert_eq!(settings.password, "secret");
        assert_eq!(settings.bypass, "localhost, *.corp");
    }

    #[test]
    fn direct_and_system_modes_ignore_manual_fields() {
        let system = build_settings(ProxyMode::System, "", 0, "", "", "").unwrap();
        assert_eq!(system.mode, ProxyMode::System);
        assert!(system.host.is_empty());

        let direct = build_settings(ProxyMode::Direct, "ignored", 1080, "user", "secret", "x")
            .unwrap();
        assert_eq!(direct.mode, ProxyMode::Direct);
        assert!(direct.host.is_empty());
        assert!(direct.username.is_empty());
        assert!(direct.bypass.is_empty());
    }
}
