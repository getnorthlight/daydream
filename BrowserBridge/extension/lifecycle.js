// No URL/title/event payload is retained. Both old and signed collectors share
// these browser-owned navigation/focus/permission invalidation boundaries.
export function bindInvalidation(api, bridge) {
  const events = [api.webNavigation.onBeforeNavigate, api.webNavigation.onCommitted,
    api.webNavigation.onHistoryStateUpdated, api.webNavigation.onReferenceFragmentUpdated,
    api.webNavigation.onErrorOccurred, api.tabs.onActivated, api.tabs.onUpdated,
    api.tabs.onRemoved, api.windows.onFocusChanged, api.windows.onRemoved];
  const permission = api.permissions.onRemoved;
  if ([...events, permission].some(event => !event?.addListener || !event?.removeListener)) throw Error('missing_lifecycle');
  const changed = () => bridge.invalidate(), removed = () => bridge.disconnect('permission_removed');
  for (const event of events) event.addListener(changed);
  permission.addListener(removed);
  return () => { for (const event of events) event.removeListener(changed); permission.removeListener(removed); };
}
