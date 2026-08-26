pub mod data {
    pub mod error {
        include!("gen/buck.data.error.rs");
    }
    include!("gen/buck.data.rs");
}

pub mod host_sharing {
    include!("gen/buck.host_sharing.rs");
}

pub mod test {
    include!("gen/buck.test.rs");
}
