//! Secure report export using directory file descriptors and an atomic rename.
use crate::{report::validate_report_xml, ContractError, ContractResult};
use std::path::Path;

#[cfg(any(target_os = "linux", target_os = "macos"))]
mod unix {
    use super::*;
    use rustix::{
        fs::{
            fstat, fsync, openat, renameat, statat, unlinkat, AtFlags, FileType, Mode, OFlags, CWD,
        },
        io::{read, retry_on_intr, write, Errno},
    };
    use std::{
        io,
        path::{Component, PathBuf},
        sync::atomic::{AtomicU64, Ordering},
    };

    const MAX_REPORT_BYTES: u64 = 64 * 1024 * 1024;
    const COPY_BUFFER_BYTES: usize = 64 * 1024;
    static TEMP_COUNTER: AtomicU64 = AtomicU64::new(0);

    fn io_error(error: Errno) -> ContractError {
        ContractError::Io(io::Error::from(error))
    }

    fn open_directory(
        parent: impl rustix::fd::AsFd,
        path: &Path,
    ) -> ContractResult<rustix::fd::OwnedFd> {
        openat(
            parent,
            path,
            OFlags::DIRECTORY | OFlags::NOFOLLOW | OFlags::CLOEXEC,
            Mode::empty(),
        )
        .map_err(io_error)
    }

    fn open_destination_parent(
        destination: &Path,
    ) -> ContractResult<(rustix::fd::OwnedFd, PathBuf)> {
        if !destination.is_absolute() {
            return Err(ContractError::invalid(
                "report destination must be absolute",
            ));
        }
        let basename = destination
            .file_name()
            .filter(|name| !name.is_empty())
            .ok_or_else(|| {
                ContractError::invalid("report destination must have a non-empty basename")
            })?;
        if !matches!(
            Path::new(basename).components().next(),
            Some(Component::Normal(_))
        ) || Path::new(basename).components().count() != 1
        {
            return Err(ContractError::invalid(
                "report destination must have a normal basename",
            ));
        }
        let parent_path = destination
            .parent()
            .ok_or_else(|| ContractError::invalid("destination has no parent"))?;
        let mut current = open_directory(CWD, Path::new("/"))?;
        for component in parent_path.components() {
            match component {
                Component::RootDir => {}
                Component::Normal(name) => {
                    current = open_directory(&current, Path::new(name))?;
                }
                Component::CurDir | Component::ParentDir | Component::Prefix(_) => {
                    return Err(ContractError::invalid(
                        "report destination parent contains an unsafe path component",
                    ));
                }
            }
        }
        Ok((current, basename.into()))
    }

    fn read_source(source: &Path) -> ContractResult<Vec<u8>> {
        let source_fd = openat(
            if source.is_absolute() {
                rustix::fs::ABS
            } else {
                CWD
            },
            source,
            OFlags::RDONLY | OFlags::NOFOLLOW | OFlags::CLOEXEC,
            Mode::empty(),
        )
        .map_err(io_error)?;
        let source_stat = fstat(&source_fd).map_err(io_error)?;
        if FileType::from_raw_mode(source_stat.st_mode) != FileType::RegularFile {
            return Err(ContractError::invalid(
                "report source must be a regular file",
            ));
        }
        if source_stat.st_size < 0 || source_stat.st_size as u64 > MAX_REPORT_BYTES {
            return Err(ContractError::invalid(
                "report source exceeds the 64 MiB limit",
            ));
        }

        let mut bytes = Vec::with_capacity(source_stat.st_size as usize);
        let mut buffer = [0u8; COPY_BUFFER_BYTES];
        loop {
            let remaining = MAX_REPORT_BYTES as usize - bytes.len();
            if remaining == 0 {
                let mut probe = [0u8; 1];
                let n = retry_on_intr(|| read(&source_fd, &mut probe)).map_err(io_error)?;
                if n != 0 {
                    return Err(ContractError::invalid(
                        "report source exceeds the 64 MiB limit",
                    ));
                }
                break;
            }
            let amount = remaining.min(buffer.len());
            let n = retry_on_intr(|| read(&source_fd, &mut buffer[..amount])).map_err(io_error)?;
            if n == 0 {
                break;
            }
            bytes.extend_from_slice(&buffer[..n]);
        }
        Ok(bytes)
    }

    struct Temporary<'a> {
        parent: &'a rustix::fd::OwnedFd,
        name: Option<PathBuf>,
        fd: rustix::fd::OwnedFd,
    }

    impl Temporary<'_> {
        fn disarm(&mut self) {
            self.name = None;
        }
    }

    impl Drop for Temporary<'_> {
        fn drop(&mut self) {
            if let Some(name) = self.name.take() {
                let _ = unlinkat(self.parent, name, AtFlags::empty());
            }
        }
    }

    fn create_temporary<'a>(parent: &'a rustix::fd::OwnedFd) -> ContractResult<Temporary<'a>> {
        let pid = std::process::id();
        for attempt in 0..128u64 {
            let counter = TEMP_COUNTER.fetch_add(1, Ordering::Relaxed);
            let name = PathBuf::from(format!(".nextest-report-{pid}-{counter}-{attempt}"));
            match openat(
                parent,
                &name,
                OFlags::WRONLY | OFlags::CREATE | OFlags::EXCL | OFlags::NOFOLLOW | OFlags::CLOEXEC,
                Mode::RUSR | Mode::WUSR,
            ) {
                Ok(fd) => {
                    return Ok(Temporary {
                        parent,
                        name: Some(name),
                        fd,
                    })
                }
                Err(Errno::EXIST) => continue,
                Err(error) => return Err(io_error(error)),
            }
        }
        Err(ContractError::Io(io::Error::new(
            io::ErrorKind::AlreadyExists,
            "could not create a unique report temporary file",
        )))
    }

    fn write_all(fd: &rustix::fd::OwnedFd, bytes: &[u8]) -> ContractResult<()> {
        let mut written = 0;
        while written < bytes.len() {
            let n = retry_on_intr(|| write(fd, &bytes[written..])).map_err(io_error)?;
            if n == 0 {
                return Err(ContractError::Io(io::Error::new(
                    io::ErrorKind::WriteZero,
                    "report temporary file write made no progress",
                )));
            }
            written += n;
        }
        Ok(())
    }

    fn validate_destination(parent: &rustix::fd::OwnedFd, basename: &Path) -> ContractResult<()> {
        match statat(parent, basename, AtFlags::SYMLINK_NOFOLLOW) {
            Ok(stat) if FileType::from_raw_mode(stat.st_mode) == FileType::RegularFile => Ok(()),
            Ok(_) => Err(ContractError::invalid(
                "report destination must be a regular file",
            )),
            Err(Errno::NOENT) => Ok(()),
            Err(error) => Err(io_error(error)),
        }
    }

    pub(super) fn export_report(source: &Path, destination: &Path) -> ContractResult<()> {
        let bytes = read_source(source)?;
        validate_report_xml(&bytes)?;
        let (parent, basename) = open_destination_parent(destination)?;
        let mut temporary = create_temporary(&parent)?;
        write_all(&temporary.fd, &bytes)?;
        fsync(&temporary.fd).map_err(io_error)?;
        validate_destination(&parent, &basename)?;
        renameat(
            &parent,
            temporary.name.as_ref().unwrap(),
            &parent,
            &basename,
        )
        .map_err(io_error)?;
        temporary.disarm();
        fsync(&parent).map_err(io_error)?;
        Ok(())
    }
}

#[cfg(any(target_os = "linux", target_os = "macos"))]
pub fn export_report(
    source: impl AsRef<Path>,
    destination: impl AsRef<Path>,
) -> ContractResult<()> {
    unix::export_report(source.as_ref(), destination.as_ref())
}

#[cfg(not(any(target_os = "linux", target_os = "macos")))]
pub fn export_report(
    _source: impl AsRef<Path>,
    _destination: impl AsRef<Path>,
) -> ContractResult<()> {
    Err(ContractError::invalid(
        "secure report export is unsupported on this platform",
    ))
}

#[cfg(all(test, any(target_os = "linux", target_os = "macos")))]
mod tests {
    use super::*;
    use std::{
        fs,
        path::PathBuf,
        sync::atomic::{AtomicU64, Ordering},
    };

    const VALID_XML: &[u8] = br#"<testsuites><testsuite/></testsuites>"#;

    fn test_directory() -> PathBuf {
        static COUNTER: AtomicU64 = AtomicU64::new(0);
        let path = std::env::current_dir().unwrap().join(format!(
            ".export-test-{}-{}",
            std::process::id(),
            COUNTER.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir(&path).unwrap();
        path
    }

    #[test]
    fn exports_to_an_absolute_destination() {
        let directory = test_directory();
        let source = directory.join("source.xml");
        let destination = directory.join("report.xml");
        fs::write(&source, VALID_XML).unwrap();

        export_report(&source, &destination).unwrap();

        assert_eq!(fs::read(&destination).unwrap(), VALID_XML);
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn rejects_an_empty_absolute_destination() {
        let directory = test_directory();
        let source = directory.join("source.xml");
        fs::write(&source, VALID_XML).unwrap();

        let error = export_report(&source, Path::new("/")).unwrap_err();
        assert!(error.to_string().contains("non-empty basename"));
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn validates_xml_before_export() {
        let directory = test_directory();
        let source = directory.join("source.xml");
        let destination = directory.join("report.xml");
        fs::write(&source, b"<testsuites>").unwrap();
        fs::write(&destination, b"old report").unwrap();

        assert!(export_report(&source, &destination).is_err());
        assert_eq!(fs::read(&destination).unwrap(), b"old report");
        fs::remove_dir_all(directory).unwrap();
    }
}
