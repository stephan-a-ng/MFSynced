# Phone mirror

```yaml
slice: phone-mirror
status: implemented-automated-validation-complete
affected_components:
  - SyncQueueDatabase phone_mirror persistence
  - ContactStore contact resolution
  - ContentView contact-update application
consumed_dependencies:
  - nexus GET /v1/agent/contact-updates
  - macOS Contacts framework
provided_interfaces:
  - persistent server-sourced phone display fallback
related_slices: []
acceptance_criteria:
  - server contact details persist for every normalized phone key
  - Apple Contacts values win when both sources match
  - mirror-only numbers resolve in chat without an Apple Contacts card
  - phone data is never written to Apple Contacts
test_ownership:
  - MFSyncedTests/SyncQueueDatabasePhoneMirrorTests.swift
  - MFSyncedTests/ContactStorePhoneMirrorTests.swift
open_decisions: []
```

## Human validation

Run the development app against an isolated nexus with a server contact update
for a number not present in Contacts.app. Open a chat for that number and
confirm its server display name/photo appear. Add a local Contacts.app card for
the same number with different details, refresh the app, and confirm the local
card wins. Confirm no phone numbers are added or changed in Contacts.app.
