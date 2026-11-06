use std::{env, path::PathBuf, process::Command};

fn main() {
    // Only watch vendor/yt-dlp when it's embedded: cargo treats a missing watched file as changed,
    // which would rerun this script (and the Go build below) and relink the server on every build.
    if env::var("CARGO_FEATURE_EMBED_YTDLP").is_ok() {
        println!("cargo:rerun-if-changed=vendor/yt-dlp");
    }
    for f in ["tsnet-ffi/main.go", "tsnet-ffi/go.mod", "tsnet-ffi/go.sum"] {
        println!("cargo:rerun-if-changed={f}");
    }
    println!("cargo:rerun-if-env-changed=YTP_GO");

    if env::var("CARGO_FEATURE_EMBEDDED_TAILSCALE").is_ok() {
        build_tsnet();
    }

    if env::var("CARGO_FEATURE_EMBED_YTDLP").is_ok() && !std::path::Path::new("vendor/yt-dlp").exists() {
        panic!("feature `embed-ytdlp` requires server/vendor/yt-dlp (run scripts/fetch-ytdlp.sh)");
    }
}

/// Compile server/tsnet-ffi (a small Go wrapper around tailscale.com/tsnet) into a static
/// library and link it in, so the server can join the tailnet without Tailscale installed.
fn build_tsnet() {
    let out = PathBuf::from(env::var("OUT_DIR").unwrap());
    let go = env::var("YTP_GO").unwrap_or_else(|_| find_go());
    let lib = out.join("libytpts.a");

    let status = Command::new(&go)
        .args(["build", "-buildmode=c-archive", "-trimpath", "-ldflags=-s -w", "-o"])
        .arg(&lib)
        .arg(".")
        .current_dir("tsnet-ffi")
        .env("CGO_ENABLED", "1")
        .status();
    match status {
        Ok(s) if s.success() => {}
        Ok(s) => panic!("building the embedded Tailscale node (server/tsnet-ffi) failed: {s}"),
        Err(e) => panic!(
            "\n\nThe embedded Tailscale node (on by default) is built with Go, but `{go}` couldn't be run: {e}\n\
             Install Go (https://go.dev/dl/) or point YTP_GO at it, or build without it:\n\
             \tcargo build --no-default-features\n\n"
        ),
    }

    println!("cargo:rustc-link-search=native={}", out.display());
    println!("cargo:rustc-link-lib=static=ytpts");
    match env::var("CARGO_CFG_TARGET_OS").unwrap_or_default().as_str() {
        "linux" => {
            println!("cargo:rustc-link-lib=dylib=pthread");
            println!("cargo:rustc-link-lib=dylib=resolv");
        }
        "macos" => {
            println!("cargo:rustc-link-lib=framework=CoreFoundation");
            println!("cargo:rustc-link-lib=framework=Security");
            println!("cargo:rustc-link-lib=framework=SystemConfiguration");
            println!("cargo:rustc-link-lib=resolv");
        }
        _ => {}
    }
}

/// `go` from PATH, or from the usual install locations (a fresh shell often lacks them on PATH).
fn find_go() -> String {
    let on_path = env::var_os("PATH")
        .map(|p| env::split_paths(&p).any(|d| d.join("go").is_file()))
        .unwrap_or(false);
    if on_path {
        return "go".into();
    }
    let home = env::var("HOME").unwrap_or_default();
    [format!("{home}/.local/go/bin/go"), "/usr/local/go/bin/go".into(), format!("{home}/go/bin/go"), "/usr/lib/go/bin/go".into()]
        .into_iter()
        .find(|p| std::path::Path::new(p).is_file())
        .unwrap_or_else(|| "go".into())
}
