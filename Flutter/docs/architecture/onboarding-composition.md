# Onboarding composition boundary

Onboarding application objects receive services through their constructors.
They must remain importable without the app composition layer. Riverpod
factories belong in `app/di/onboarding_providers.dart`; controller files must
not import or re-export that module. Global bootstrap providers must not
import it back, including through another library.

This boundary prevents application assembly from becoming a circular service
locator. It does not change who owns state: continuation checkpoints remain
account/workspace scoped, pending submission keeps its existing temporary
keep-alive, and task finalization remains independent of the questionnaire
page. Moving a factory must preserve watch/read choices, disposal callbacks,
provider overrides and notification identity.

Pages and application-level consumers import the factories explicitly. The
dependency boundary test checks transitive imports; behavioral onboarding and
navigation tests verify lifetime and recovery semantics. Cross-feature data
contracts and the remaining global provider modules are separate extraction
work, not permission to restore the reverse dependency.
