//! Compatibility API for startup/panic callers; automatic reporting is disabled.

use std::path::Path;

/// No client, identity, report queue, or on-disk reporting budget is created.
#[derive(Clone)]
pub struct StartupReporter;

impl StartupReporter {
    pub async fn from_dir(_browserclaw_dir: &Path) -> Self {
        Self
    }

    pub fn report(&self, _kind: &'static str, _label: &str, _detail: Option<&str>) {}
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[tokio::test]
    async fn startup_reporting_does_not_create_state_or_payload_files() -> anyhow::Result<()> {
        let dir = tempdir()?;
        let reporter = StartupReporter::from_dir(dir.path()).await;
        reporter.report("startup", "init_failed", Some("must not be collected"));
        reporter.clone().report("panic", "panic", None);
        assert_eq!(std::fs::read_dir(dir.path())?.count(), 0);
        Ok(())
    }
}
