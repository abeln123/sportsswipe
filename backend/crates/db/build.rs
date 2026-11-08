fn main() {
    // SQLx embeds migrations; adding a migration must invalidate the crate cache.
    println!("cargo:rerun-if-changed=migrations");
}
