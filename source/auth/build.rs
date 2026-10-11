fn main() {
    cc::Build::new().file("src/native_validation.m").flag("-fobjc-arc").compile("native_validation");
    println!("cargo:rustc-link-lib=framework=Foundation");
    println!("cargo:rerun-if-changed=src/native_validation.m");
}
