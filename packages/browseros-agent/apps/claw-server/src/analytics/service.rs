use super::{
    AnalyticsSink,
    events::EventDefinition,
    state::{AnalyticsState, TelemetryState, load_or_create_state, persist_state, state_path},
};
use crate::error::{AppError, AppResult};
use serde_json::Value;
use std::path::{Path, PathBuf};
use tokio::sync::Mutex;

#[cfg(test)]
use std::sync::atomic::{AtomicUsize, Ordering};

/// Preserves the local settings API without collecting or delivering analytics.
/// There is deliberately no SDK client, queue, alias worker, or credential lookup.
pub struct AnalyticsService {
    path: PathBuf,
    state: Mutex<AnalyticsState>,
    #[cfg(test)]
    shutdown_calls: AtomicUsize,
}

impl AnalyticsService {
    pub async fn new(browserclaw_dir: impl AsRef<Path>) -> AppResult<Self> {
        let path = state_path(browserclaw_dir.as_ref());
        let state = load_or_create_state(&path).await;
        Ok(Self {
            path,
            state: Mutex::new(state),
            #[cfg(test)]
            shutdown_calls: AtomicUsize::new(0),
        })
    }

    #[cfg(test)]
    pub(crate) async fn new_for_test(
        browserclaw_dir: &Path,
        _project_key: Option<&str>,
        _host: String,
        _environment_enabled: bool,
    ) -> AppResult<Self> {
        Self::new(browserclaw_dir).await
    }

    #[cfg(test)]
    pub(crate) fn shutdown_calls_for_testing(&self) -> usize {
        self.shutdown_calls.load(Ordering::SeqCst)
    }

    #[must_use]
    pub fn remote_config_credentials(&self) -> Option<(String, String)> {
        None
    }

    pub async fn get_state(&self) -> TelemetryState {
        let state = self.state.lock().await;
        Self::telemetry_state(&state)
    }

    /// Persist the preference for API compatibility, but never activate delivery.
    pub async fn set_consent(&self, consent: bool) -> AppResult<TelemetryState> {
        let mut state = self.state.lock().await;
        let mut next = state.clone();
        next.enabled = consent;
        if let Err(source) = persist_state(&self.path, &next).await {
            if !consent {
                *state = next;
            }
            return Err(AppError::Io {
                path: Some(self.path.clone()),
                source,
            });
        }
        *state = next;
        Ok(Self::telemetry_state(&state))
    }

    pub fn capture(&self, _definition: EventDefinition, _properties: Value) {}

    pub async fn shutdown(&self) {
        #[cfg(test)]
        self.shutdown_calls.fetch_add(1, Ordering::SeqCst);
    }

    fn telemetry_state(state: &AnalyticsState) -> TelemetryState {
        TelemetryState {
            distinct_id: state.distinct_id.clone().unwrap_or_default(),
            enabled: false,
            consent: state.enabled,
        }
    }
}

impl AnalyticsSink for AnalyticsService {
    fn capture(&self, event: EventDefinition, properties: Value) {
        Self::capture(self, event, properties);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::analytics::events::SERVER_STARTED;
    use serde_json::json;
    use tempfile::tempdir;

    #[tokio::test]
    async fn automatic_telemetry_stays_disabled_with_credentials_and_consent() -> anyhow::Result<()>
    {
        let root = tempdir()?;
        let service = AnalyticsService::new_for_test(
            root.path(),
            Some("test-key"),
            "http://127.0.0.1:1".to_string(),
            true,
        )
        .await?;
        let initial = service.get_state().await;
        assert!(!initial.enabled);
        assert!(!initial.distinct_id.is_empty());
        assert!(service.remote_config_credentials().is_none());
        for consent in [false, true, true] {
            let state = service.set_consent(consent).await?;
            assert_eq!(state.consent, consent);
            assert_eq!(state.distinct_id, initial.distinct_id);
            assert!(!state.enabled);
            service.capture(SERVER_STARTED, json!({}));
        }
        service.shutdown().await;
        let restarted = AnalyticsService::new(root.path()).await?;
        let state = restarted.get_state().await;
        assert!(state.consent);
        assert!(!state.enabled);
        assert_eq!(state.distinct_id, initial.distinct_id);
        Ok(())
    }
}
