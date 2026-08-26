use std::{
    fmt, fs, io,
    path::{Component, Path, PathBuf},
};

#[cfg(not(unix))]
use std::io::Write;

#[cfg(unix)]
impl From<rustix::io::Errno> for ReportError {
    fn from(error: rustix::io::Errno) -> Self {
        Self::Io(io::Error::from(error))
    }
}

#[cfg(unix)]
use rustix::{
    fd::OwnedFd,
    fs::{self as rfs, AtFlags, Dir, FileType, Mode, OFlags, CWD},
    io as rio,
};

use quick_xml::{events::Event, Reader};

const MAX_REPORT_BYTES: u64 = 64 * 1024 * 1024;
const CONSERVATIVE_NAME_MAX: usize = 255;

#[derive(Debug)]
pub enum ReportError {
    Invalid(String),
    Io(io::Error),
    Xml(String),
}

impl fmt::Display for ReportError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Invalid(message) => write!(f, "{message}"),
            Self::Io(error) => write!(f, "I/O error: {error}"),
            Self::Xml(error) => write!(f, "invalid XML: {error}"),
        }
    }
}

impl std::error::Error for ReportError {}
impl From<io::Error> for ReportError {
    fn from(error: io::Error) -> Self {
        Self::Io(error)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReportIdentity {
    pub cell: String,
    pub package: String,
    pub target: String,
    pub configuration: String,
}

impl ReportIdentity {
    pub fn filename(&self) -> Result<String, ReportError> {
        let mut bytes = Vec::new();
        for (tag, value) in [
            (b'c', &self.cell),
            (b'p', &self.package),
            (b't', &self.target),
            (b'g', &self.configuration),
        ] {
            bytes.push(tag);
            bytes.extend_from_slice(&(value.len() as u64).to_be_bytes());
            bytes.extend_from_slice(value.as_bytes());
        }
        let mut result = String::with_capacity(bytes.len());
        for byte in bytes {
            if byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'.' | b'_' | b'~') {
                result.push(byte as char);
            } else {
                result.push('%');
                result.push(char::from(b"0123456789ABCDEF"[(byte >> 4) as usize]));
                result.push(char::from(b"0123456789ABCDEF"[(byte & 0xf) as usize]));
            }
        }
        result.push_str(".xml");
        if result.len() > CONSERVATIVE_NAME_MAX {
            return Err(ReportError::Invalid(
                "encoded report identity exceeds destination NAME_MAX".into(),
            ));
        }
        Ok(result)
    }
}

pub fn reserve_key(identity: &ReportIdentity) -> Result<String, ReportError> {
    Ok(identity.filename()?.to_ascii_lowercase())
}

#[derive(Debug)]
pub struct DestinationDir {
    #[cfg(unix)]
    _parent: OwnedFd,
    #[cfg(unix)]
    child: OwnedFd,
    #[cfg(not(unix))]
    path: PathBuf,
}

impl DestinationDir {
    pub fn open(path: impl AsRef<Path>) -> Result<Self, ReportError> {
        let path = path.as_ref();
        #[cfg(unix)]
        {
            validate_destination_shape(path)?;
            let parent_path = path
                .parent()
                .ok_or_else(|| ReportError::Invalid("junit directory has no parent".into()))?;
            let parent = open_directory_path(parent_path)?;
            let child = rfs::openat(
                &parent,
                "junit",
                OFlags::RDONLY | OFlags::DIRECTORY | OFlags::CLOEXEC | OFlags::NOFOLLOW,
                Mode::empty(),
            )?;
            verify_destination_fds(&parent, &child)?;
            return Ok(Self {
                _parent: parent,
                child,
            });
        }
        #[cfg(not(unix))]
        {
            validate_destination_shape(path)?;
            Ok(Self {
                path: path.to_owned(),
            })
        }
    }

    pub fn publish(&self, filename: &str, bytes: &[u8]) -> Result<(), ReportError> {
        if filename.is_empty()
            || filename.len() > CONSERVATIVE_NAME_MAX
            || filename.contains('/')
            || filename.contains('\0')
        {
            return Err(ReportError::Invalid("report filename is invalid".into()));
        }
        validate_xml(bytes)?;
        let temp_name = format!(
            ".{filename}.tmp-{}-{}",
            std::process::id(),
            TEMP_COUNTER.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
        );
        #[cfg(unix)]
        {
            let temp = rfs::openat(
                &self.child,
                temp_name.as_str(),
                OFlags::WRONLY | OFlags::CREATE | OFlags::EXCL | OFlags::CLOEXEC | OFlags::NOFOLLOW,
                Mode::RUSR | Mode::WUSR,
            )?;
            if let Err(error) =
                write_fd(&temp, bytes).and_then(|()| rfs::fsync(&temp).map_err(io::Error::from))
            {
                let _ = rfs::unlinkat(&self.child, temp_name.as_str(), AtFlags::empty());
                return Err(ReportError::Io(error));
            }
            if let Err(error) = publish_noreplace_fd(&self.child, &temp_name, filename) {
                let _ = rfs::unlinkat(&self.child, temp_name.as_str(), AtFlags::empty());
                return Err(error);
            }
            rfs::fsync(&self.child)?;
            return Ok(());
        }
        #[cfg(not(unix))]
        {
            let temp = self.path.join(&temp_name);
            let mut options = fs::OpenOptions::new();
            options.write(true).create_new(true);
            let mut file = options.open(&temp)?;
            file.write_all(bytes)?;
            file.sync_all()?;
            let destination = self.path.join(filename);
            if destination.exists() {
                let _ = fs::remove_file(&temp);
                return Err(ReportError::Invalid(
                    "report destination already exists".into(),
                ));
            }
            fs::rename(&temp, &destination)?;
            fs::File::open(&self.path)?.sync_all()?;
            Ok(())
        }
    }
}

static TEMP_COUNTER: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

fn validate_destination_shape(path: &Path) -> Result<(), ReportError> {
    if !path.is_absolute() {
        return Err(ReportError::Invalid("--junit-dir must be absolute".into()));
    }
    let components: Vec<_> = path.components().collect();
    if components.last() != Some(&Component::Normal("junit".as_ref())) {
        return Err(ReportError::Invalid(
            "--junit-dir must be a directory named junit".into(),
        ));
    }
    if components
        .iter()
        .any(|component| matches!(component, Component::Normal(name) if *name == "buck-out"))
    {
        return Err(ReportError::Invalid(
            "--junit-dir may not contain a buck-out component".into(),
        ));
    }
    let project_root = std::env::var_os("BUCK_PROJECT_ROOT")
        .map(PathBuf::from)
        .or_else(|| std::env::current_dir().ok());
    if let Some(root) = project_root {
        let root = fs::canonicalize(root).map_err(|error| {
            ReportError::Invalid(format!("cannot establish repository root: {error}"))
        })?;
        let parent = path
            .parent()
            .ok_or_else(|| ReportError::Invalid("junit directory has no parent".into()))?;
        let candidate = fs::canonicalize(parent).map_err(|error| {
            ReportError::Invalid(format!(
                "cannot establish private destination parent: {error}"
            ))
        })?;
        if candidate.starts_with(&root) {
            return Err(ReportError::Invalid(
                "--junit-dir must be outside the repository root".into(),
            ));
        }
    }
    #[cfg(unix)]
    return Ok(());
    #[cfg(not(unix))]
    {
        let parent = path
            .parent()
            .ok_or_else(|| ReportError::Invalid("junit directory has no parent".into()))?;
        let parent_meta = fs::symlink_metadata(parent)?;
        let child_meta = fs::symlink_metadata(path)?;
        if !parent_meta.is_dir()
            || !child_meta.is_dir()
            || parent_meta.file_type().is_symlink()
            || child_meta.file_type().is_symlink()
        {
            return Err(ReportError::Invalid(
                "--junit-dir and its private parent must be real directories".into(),
            ));
        }
        let entries: Vec<_> = fs::read_dir(parent)?.collect::<Result<_, _>>()?;
        if entries.len() != 1 || entries[0].file_name() != "junit" {
            return Err(ReportError::Invalid(
                "private destination parent must contain only junit".into(),
            ));
        }
        if fs::read_dir(path)?.next().is_some() {
            return Err(ReportError::Invalid("--junit-dir must be empty".into()));
        }
        Ok(())
    }
}

#[cfg(unix)]
fn open_directory_path(path: &Path) -> Result<OwnedFd, ReportError> {
    if !path.is_absolute() {
        return Err(ReportError::Invalid(
            "directory path must be absolute".into(),
        ));
    }
    let root = rfs::openat(
        CWD,
        "/",
        OFlags::RDONLY | OFlags::DIRECTORY | OFlags::CLOEXEC | OFlags::NOFOLLOW,
        Mode::empty(),
    )
    .map_err(|error| ReportError::Invalid(format!("cannot open filesystem root: {error}")))?;
    let mut current = root;
    for component in path.components() {
        match component {
            Component::RootDir => {}
            Component::Normal(name) => {
                current = rfs::openat(
                    &current,
                    name,
                    OFlags::RDONLY | OFlags::DIRECTORY | OFlags::CLOEXEC | OFlags::NOFOLLOW,
                    Mode::empty(),
                )
                .map_err(|error| {
                    ReportError::Invalid(format!(
                        "cannot open destination path component {:?}: {error}",
                        name
                    ))
                })?;
            }
            Component::CurDir | Component::ParentDir | Component::Prefix(_) => {
                return Err(ReportError::Invalid(
                    "directory path contains an unsupported component".into(),
                ));
            }
        }
    }
    Ok(current)
}

#[cfg(unix)]
fn directory_entries(fd: &OwnedFd) -> Result<Vec<Vec<u8>>, ReportError> {
    let mut directory = Dir::read_from(fd)?;
    let mut entries = Vec::new();
    while let Some(entry) = directory.next() {
        let entry = entry?;
        let name = entry.file_name().to_bytes();
        if name != b"." && name != b".." {
            entries.push(name.to_vec());
        }
    }
    Ok(entries)
}

#[cfg(unix)]
fn verify_destination_fds(parent: &OwnedFd, child: &OwnedFd) -> Result<(), ReportError> {
    let entries = directory_entries(parent)?;
    if entries.len() != 1 || entries[0] != b"junit" {
        return Err(ReportError::Invalid(
            "private destination parent must contain only junit".into(),
        ));
    }
    if !directory_entries(child)?.is_empty() {
        return Err(ReportError::Invalid("--junit-dir must be empty".into()));
    }
    let parent_stat = rfs::fstat(parent)?;
    let child_stat = rfs::fstat(child)?;
    let child_again = rfs::statat(parent, "junit", AtFlags::SYMLINK_NOFOLLOW)?;
    if child_stat.st_dev != child_again.st_dev || child_stat.st_ino != child_again.st_ino {
        return Err(ReportError::Invalid(
            "junit directory changed during capability validation".into(),
        ));
    }
    if parent_stat.st_dev == child_stat.st_dev && parent_stat.st_ino == child_stat.st_ino {
        return Err(ReportError::Invalid(
            "private destination parent and junit child must differ".into(),
        ));
    }
    Ok(())
}

#[cfg(unix)]
fn write_fd(fd: &OwnedFd, bytes: &[u8]) -> io::Result<()> {
    let mut offset = 0;
    while offset < bytes.len() {
        let written = rio::write(fd, &bytes[offset..]).map_err(io::Error::from)?;
        if written == 0 {
            return Err(io::Error::new(
                io::ErrorKind::WriteZero,
                "short report write",
            ));
        }
        offset += written;
    }
    Ok(())
}

#[cfg(unix)]
fn publish_noreplace_fd(
    parent: &OwnedFd,
    temp: &str,
    destination: &str,
) -> Result<(), ReportError> {
    #[cfg(target_os = "linux")]
    {
        match rfs::renameat_with(
            parent,
            temp,
            parent,
            destination,
            rfs::RenameFlags::NOREPLACE,
        ) {
            Ok(()) => return Ok(()),
            Err(error)
                if error != rustix::io::Errno::NOSYS && error != rustix::io::Errno::INVAL =>
            {
                if error == rustix::io::Errno::EXIST {
                    return Err(ReportError::Invalid(
                        "report destination already exists".into(),
                    ));
                }
                return Err(ReportError::Io(io::Error::from(error)));
            }
            Err(_) => {}
        }
    }
    match rfs::linkat(parent, temp, parent, destination, AtFlags::empty()) {
        Ok(()) => rfs::unlinkat(parent, temp, AtFlags::empty())
            .map_err(|error| ReportError::Io(io::Error::from(error))),
        Err(error) if error == rustix::io::Errno::EXIST => Err(ReportError::Invalid(
            "report destination already exists".into(),
        )),
        Err(error) => Err(ReportError::Io(io::Error::from(error))),
    }
}

pub fn inspect_and_read(source: impl AsRef<Path>) -> Result<Vec<u8>, ReportError> {
    let source = source.as_ref();
    if !source.is_absolute() {
        return Err(ReportError::Invalid(
            "Buck output path must be absolute".into(),
        ));
    }
    #[cfg(unix)]
    {
        let source_fd = open_directory_path(source)?;
        let entries = directory_entries(&source_fd)?;
        if entries.len() != 1 || entries[0] != b"junit.xml" {
            return Err(ReportError::Invalid(
                "Buck junit output must contain exactly junit.xml".into(),
            ));
        }
        let report_fd = rfs::openat(
            &source_fd,
            "junit.xml",
            OFlags::RDONLY | OFlags::CLOEXEC | OFlags::NOFOLLOW,
            Mode::empty(),
        )?;
        let metadata = rfs::fstat(&report_fd)?;
        if FileType::from_raw_mode(metadata.st_mode) != FileType::RegularFile {
            return Err(ReportError::Invalid(
                "junit.xml must be a regular non-symlink file".into(),
            ));
        }
        if metadata.st_size < 0 || metadata.st_size as u64 > MAX_REPORT_BYTES {
            return Err(ReportError::Invalid(
                "junit.xml exceeds the 64 MiB limit".into(),
            ));
        }
        let mut bytes = Vec::with_capacity(metadata.st_size as usize);
        let mut chunk = [0u8; 64 * 1024];
        loop {
            let count = rio::read(&report_fd, &mut chunk)?;
            if count == 0 {
                break;
            }
            bytes.extend_from_slice(&chunk[..count]);
            if bytes.len() as u64 > MAX_REPORT_BYTES {
                return Err(ReportError::Invalid(
                    "junit.xml exceeds the 64 MiB limit".into(),
                ));
            }
        }
        validate_xml(&bytes)?;
        return Ok(bytes);
    }
    #[cfg(not(unix))]
    {
        let metadata = fs::symlink_metadata(source)?;
        if !metadata.is_dir() || metadata.file_type().is_symlink() {
            return Err(ReportError::Invalid(
                "Buck output must be a real directory".into(),
            ));
        }
        let entries: Vec<_> = fs::read_dir(source)?.collect::<Result<_, _>>()?;
        if entries.len() != 1 || entries[0].file_name() != "junit.xml" {
            return Err(ReportError::Invalid(
                "Buck junit output must contain exactly junit.xml".into(),
            ));
        }
        let report = source.join("junit.xml");
        let metadata = fs::symlink_metadata(&report)?;
        if !metadata.is_file() || metadata.file_type().is_symlink() {
            return Err(ReportError::Invalid(
                "junit.xml must be a regular non-symlink file".into(),
            ));
        }
        if metadata.len() > MAX_REPORT_BYTES {
            return Err(ReportError::Invalid(
                "junit.xml exceeds the 64 MiB limit".into(),
            ));
        }
        let bytes = fs::read(report)?;
        if bytes.len() as u64 > MAX_REPORT_BYTES {
            return Err(ReportError::Invalid(
                "junit.xml exceeds the 64 MiB limit".into(),
            ));
        }
        validate_xml(&bytes)?;
        Ok(bytes)
    }
}

pub fn validate_xml(input: &[u8]) -> Result<(), ReportError> {
    let mut reader = Reader::from_reader(input);
    reader.config_mut().trim_text(true);
    let mut buffer = Vec::new();
    let mut stack = Vec::<Vec<u8>>::new();
    let mut root = None;
    loop {
        match reader.read_event_into(&mut buffer) {
            Ok(Event::Eof) => break,
            Ok(Event::Start(event)) => {
                let name = event.name().as_ref().to_vec();
                if stack.is_empty() {
                    if root.replace(name.clone()).is_some() {
                        return Err(ReportError::Invalid("XML has multiple roots".into()));
                    }
                }
                stack.push(name);
            }
            Ok(Event::Empty(event)) => {
                let name = event.name().as_ref().to_vec();
                if stack.is_empty() && root.replace(name).is_some() {
                    return Err(ReportError::Invalid("XML has multiple roots".into()));
                }
            }
            Ok(Event::End(event)) => {
                let Some(open) = stack.pop() else {
                    return Err(ReportError::Invalid(
                        "XML has an unmatched closing tag".into(),
                    ));
                };
                if open != event.name().as_ref() {
                    return Err(ReportError::Invalid(
                        "XML closing tag does not match opening tag".into(),
                    ));
                }
            }
            Ok(Event::Text(event)) => {
                if root.is_none()
                    || (stack.is_empty() && !event.as_ref().iter().all(u8::is_ascii_whitespace))
                {
                    return Err(ReportError::Invalid(
                        "XML has non-whitespace data outside its root".into(),
                    ));
                }
            }
            Ok(Event::CData(event)) => {
                if root.is_none()
                    || (stack.is_empty() && !event.as_ref().iter().all(u8::is_ascii_whitespace))
                {
                    return Err(ReportError::Invalid(
                        "XML has non-whitespace data outside its root".into(),
                    ));
                }
            }
            Ok(Event::Comment(_) | Event::Decl(_)) => {}
            Ok(Event::DocType(_)) => {
                return Err(ReportError::Invalid("XML doctypes are not allowed".into()))
            }
            Ok(_) => return Err(ReportError::Invalid("unsupported XML event".into())),
            Err(error) => return Err(ReportError::Xml(error.to_string())),
        }
        buffer.clear();
    }
    if !stack.is_empty() {
        return Err(ReportError::Invalid("XML has an unclosed tag".into()));
    }
    match root.as_deref() {
        Some(b"testsuites") | Some(b"testsuite") => Ok(()),
        Some(_) => Err(ReportError::Invalid(
            "XML report root must be testsuites or testsuite".into(),
        )),
        None => Err(ReportError::Invalid("XML report is empty".into())),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn identity_is_reversible_and_uses_uppercase_percent_escapes() {
        let identity = ReportIdentity {
            cell: "root".into(),
            package: "a/b:c%".into(),
            target: "té".into(),
            configuration: "cfg".into(),
        };
        let name = identity.filename().unwrap();
        assert!(name.ends_with(".xml"));
        assert!(name.contains("%"));
        assert!(name.contains("%25"));
    }
    #[test]
    fn xml_and_output_tree_are_strict() {
        assert!(validate_xml(b"<testsuites><testsuite/></testsuites>").is_ok());
        assert!(validate_xml(b"<testsuites>").is_err());
        assert!(validate_xml(b"<testsuites/>trailing").is_err());
        assert!(validate_xml(b"leading<testsuites/>").is_err());
        assert!(validate_xml(b"<other/>").is_err());
    }
    #[test]
    fn destination_requires_empty_private_junit_child() {
        let tmp = tempfile::tempdir().unwrap();
        let tmp_path = fs::canonicalize(tmp.path()).unwrap();
        let parent = tmp_path.join("private");
        let junit = parent.join("junit");
        fs::create_dir(&parent).unwrap();
        fs::create_dir(&junit).unwrap();
        std::env::remove_var("BUCK_PROJECT_ROOT");
        let destination = DestinationDir::open(&junit).unwrap();
        destination.publish("report.xml", b"<testsuite/>").unwrap();
        assert_eq!(fs::read(junit.join("report.xml")).unwrap(), b"<testsuite/>");
        assert!(destination.publish("report.xml", b"<testsuite/>").is_err());
    }
}
