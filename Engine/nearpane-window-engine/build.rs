// Build the small Apple SDK shims with Apple's headers for the requested Cargo target.
use std::{
    env,
    path::{Path, PathBuf},
    process::Command,
};

fn run(command: &mut Command) {
    assert!(
        command.status().expect("launch Apple SDK tool").success(),
        "SDK tool failed: {command:?}"
    );
}
fn main() {
    println!("cargo:rerun-if-changed=include");
    println!("cargo:rerun-if-changed=src/input_state.h");
    println!("cargo:rerun-if-changed=src/corner/scope_binding.h");
    println!("cargo:rerun-if-changed=src/corner/patch_site.h");
    println!("cargo:rerun-if-changed=src/spaces/binding-attributes.h");
    if env::var("CARGO_CFG_TARGET_OS").as_deref() != Ok("macos") {
        return;
    }
    let arch = match env::var("CARGO_CFG_TARGET_ARCH").as_deref() {
        Ok("aarch64") => "arm64",
        Ok("x86_64") => "x86_64",
        _ => panic!("unsupported macOS architecture"),
    };
    let out = PathBuf::from(env::var_os("OUT_DIR").unwrap());
    let mut objects = Vec::new();
    for (feature, file) in [
        ("CORNER", "src/corner/macos.m"),
        ("CORNER", "src/corner/patch_sheet.m"),
        ("SPACES", "src/spaces/platform.m"),
        ("ISOLATED_FIXTURES", "src/fixture.m"),
    ] {
        println!("cargo:rerun-if-changed={file}");
        if env::var_os(format!("CARGO_FEATURE_{feature}")).is_none() {
            continue;
        }
        let obj = out.join(Path::new(file).with_extension("o").file_name().unwrap());
        run(Command::new("xcrun")
            .args([
                "--sdk",
                "macosx",
                "clang",
                "-arch",
                arch,
                "-mmacosx-version-min=14.0",
                "-fobjc-arc",
                "-fvisibility=hidden",
                "-Wall",
                "-Werror=return-type",
                "-c",
                file,
                "-o",
            ])
            .arg(&obj));
        objects.push(obj);
        if let Some(dir) = Path::new(file).parent() {
            println!("cargo:rerun-if-changed={}", dir.display());
        }
    }
    if !objects.is_empty() {
        let archive = out.join("libnp_apple.a");
        run(Command::new("xcrun")
            .args(["libtool", "-static", "-o"])
            .arg(&archive)
            .args(objects));
        println!("cargo:rustc-link-search=native={}", out.display());
        println!("cargo:rustc-link-lib=static=np_apple");
    }
    if env::var_os("CARGO_FEATURE_CORNER").is_some() {
        // clang normally links its availability-check runtime for the 14.2 capture API.
        // Standalone Rust executables use -nodefaultlibs, so pass the selected SDK's
        // archive to their final link. Swift links the static library in the usual way.
        let selected = Command::new("xcrun")
            .args(["--sdk", "macosx", "clang", "--print-file-name=libclang_rt.osx.a"])
            .output().expect("find Apple compiler runtime");
        assert!(selected.status.success(), "Apple compiler runtime lookup failed");
        let path = PathBuf::from(std::str::from_utf8(&selected.stdout).expect("compiler runtime path").trim());
        assert!(path.is_absolute() && path.is_file(), "Apple compiler runtime unavailable");
        println!("cargo:rustc-link-arg={}", path.display());
    }
    for name in [
        "CoreFoundation",
        "CoreGraphics",
        "AppKit",
        "QuartzCore",
        "Foundation",
        "ApplicationServices",
        "Carbon",
        "ImageIO",
        "ScreenCaptureKit",
        "Security",
    ] {
        println!("cargo:rustc-link-lib=framework={name}");
    }
}
