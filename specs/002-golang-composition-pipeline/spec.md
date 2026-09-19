# Feature Specification: Golang Composition Function Pipeline (Registry + Helm + Dataplanes Repo)

**Feature Branch**: `002-golang-composition-pipeline`

**Created**: 2026-09-19

**Status**: Draft

**Input**: User description: "quero uma composition de exemplo mais construida, em golang. hospede no gogs. também devo ter um registry privado, para hospedar essas imagens. depois, os dataplanes devem ter um repositorio proprio para suas declarações. (ex.: dataplanes, na pasta com o nome do dataplane, fica o arquivo de values) e sempre use helm para aplicar as compositions"

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Provision a dataplane through the advanced composition by declaring it in Git (Priority: P1)

A platform operator wants a richer, more realistic dataplane than the current
namespace+deployment+service example. Instead of hand-writing a claim, the operator
adds one new directory (named after the dataplane) to a dedicated "dataplanes"
repository, with one file inside describing that dataplane's parameters (target
spoke, image, replica count, and similar settings). Once that directory is pushed,
the dataplane comes to life in the chosen spoke, built by a more advanced piece of
composition logic than the original example — one that also sets standardized
labels/annotations and sane resource settings on what it creates, rather than the
bare minimum.

**Why this priority**: This is the full value loop the feature exists to deliver: an
operator's only interaction is a Git change to a values file, and everything else —
resolving the right composition logic, talking to the right spoke, applying the
release — happens automatically. Without this working end-to-end there is nothing to
demonstrate.

**Independent Test**: Add a new directory with a values file to the dataplanes
repository targeting a registered spoke, push it, and confirm — by inspecting that
spoke directly — that the expected richer set of resources (not just the bare
namespace/deployment/service) now exists there with the requested parameters
applied.

**Acceptance Scenarios**:

1. **Given** a registered spoke and the dataplanes repository reachable from the hub,
   **When** an operator adds a new directory with a values file naming that spoke,
   **Then** the corresponding dataplane resources appear in that spoke without any
   direct `kubectl`/cluster command from the operator.
2. **Given** a dataplane already provisioned this way, **When** the operator edits
   that dataplane's values file (e.g., changes replica count), **Then** the running
   dataplane in the spoke converges to reflect the new value.
3. **Given** a dataplane's directory is removed from the repository, **When** the
   removal is picked up, **Then** the dataplane's resources are removed from the
   target spoke.

---

### User Story 2 - Build and host the composition function without any external dependency (Priority: P2)

A platform engineer changes the advanced composition's logic (its source lives in
its own repository in the internal Git service), builds a new image, and publishes it
to a registry that lives inside this lab — no public/external registry involved. The
composition's installation and upgrades are always performed as a package (chart)
release rather than by hand-applying loose files.

**Why this priority**: Builds directly on User Story 1 — without an internal place to
publish the function's image and package it, the "advanced composition" from Story 1
cannot exist in the first place. It is P2 rather than P1 because, for a first
provisioning demo, one already-published version is enough; the ability to *change and
republish* is what makes the pattern sustainable rather than a one-off.

**Independent Test**: Publish a new version of the composition function's image to the
internal registry, release the updated package, and confirm the running composition
picks up the new logic — without pulling anything from outside the lab and without any
loose-manifest `kubectl apply` for the upgrade.

**Acceptance Scenarios**:

1. **Given** the composition function's source in its own internal repository,
   **When** a platform engineer builds and publishes a new image tag to the internal
   registry, **Then** that image is pullable from inside the lab without reaching the
   public internet.
2. **Given** a new image tag has been published, **When** the engineer releases the
   updated package for that composition, **Then** the composition's running logic
   updates to the new version without any manifest being applied by hand outside of
   the package release.

---

### User Story 3 - Manage many dataplanes independently through the same repository (Priority: P3)

With more than one dataplane declared in the dataplanes repository, a platform
operator adds, edits, or removes one dataplane's directory and sees only that
dataplane affected — no shared file (the composition, its package, or the automation
that discovers dataplane directories) needs to change, no matter how many dataplanes
already exist.

**Why this priority**: Confirms the "one directory per dataplane" pattern actually
scales, the same way the original spoke-registration pattern had to prove it scaled
past two spokes. The lab is already useful with a single dataplane demoed in User
Story 1, so this is valuable but not blocking.

**Independent Test**: With two or more dataplanes already provisioned, add a third
dataplane directory (or edit/remove one of the existing ones) and confirm the other
dataplanes are left completely untouched, with no edits needed anywhere outside that
one directory.

**Acceptance Scenarios**:

1. **Given** two dataplanes already provisioned from the repository, **When** a third
   dataplane directory is added, **Then** the third dataplane is provisioned and the
   first two are unaffected.
2. **Given** three dataplanes already provisioned, **When** one dataplane's directory
   is removed, **Then** only that dataplane is deprovisioned and the remaining two
   keep running unaffected.

---

### Edge Cases

- What happens when a values file names a spoke that is not registered? The
  dataplane MUST surface a clear failure/error status rather than silently
  succeeding or landing on the wrong spoke (same contract as the existing
  provisioning model).
- What happens when a values file is malformed or missing a required parameter? The
  system MUST surface a clear failure for that dataplane directory only, without
  affecting other already-provisioned dataplanes.
- What happens when two dataplane directories use the same target spoke? Each MUST
  still get fully isolated resources in that spoke, with no collision, matching the
  existing isolation guarantee.
- What happens when the internal registry is temporarily unreachable while a
  dataplane's workload is (re)starting and needs to pull the composition function's
  image? The system MUST recover and converge once the registry is reachable again,
  rather than failing permanently.
- What happens when a dataplane's directory in the repository is renamed? The system
  MUST treat this as removing the old dataplane and provisioning a new one under the
  new name, not as an in-place rename of the running resources.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST provide an advanced example composition that, compared to
  the existing baseline example, composes a richer set of resources for a dataplane
  (at minimum a namespace, a workload with defined resource requests/limits, a way to
  reach it, and configuration data) with consistently applied labels/annotations.
- **FR-002**: The advanced composition's logic MUST be implemented as source code
  hosted in its own dedicated repository in the internal Git service, separate from
  the platform GitOps repository and from the dataplanes repository.
- **FR-003**: System MUST provide a private, internally-reachable image registry,
  provisioned through the same GitOps automation as the rest of the platform, to host
  the images the advanced composition depends on.
- **FR-004**: Once published internally, the advanced composition's image MUST be
  pullable for normal operation without reaching any registry outside this lab.
- **FR-005**: Installing or upgrading any composition exposed through the platform's
  continuous-delivery tooling MUST be done by releasing a package (chart), not by
  applying a directory of loose manifests.
- **FR-006**: System MUST provide a dedicated repository in the internal Git service
  (the "dataplanes" repository) structured as one directory per dataplane instance,
  where the directory name is the dataplane's name.
- **FR-007**: Each dataplane directory MUST contain a single values file declaring
  that dataplane's parameters (at minimum: target spoke, image, replica count).
- **FR-008**: System MUST automatically discover directories added to, changed in, or
  removed from the dataplanes repository and provision, update, or deprovision the
  corresponding dataplane accordingly, with no manual per-dataplane configuration
  step outside of that directory.
- **FR-009**: Provisioning, updating, or removing one dataplane's directory MUST NOT
  affect any other dataplane's resources.
- **FR-010**: The existing baseline example (namespace + deployment + service via the
  original composition) MUST continue to work end-to-end, unmodified, after this
  feature is delivered.
- **FR-011**: Any credential required to publish to or pull from the private registry
  MUST be generated and stored out-of-band (never committed to Git), consistent with
  how other credentials in this platform are handled.

### Key Entities

- **Composition Function Source Repository**: Internal Git repository holding the
  advanced composition's source code and packaging, independent from the platform
  GitOps repository.
- **Private Image Registry**: Internally-hosted, GitOps-provisioned service that
  stores the container image(s) the advanced composition depends on.
- **Composition Package (Chart)**: The unit used to install and upgrade a composition
  through the platform's continuous-delivery tooling, replacing ad-hoc manifest
  directories for that purpose.
- **Dataplanes Repository**: Internal Git repository whose structure is one directory
  per dataplane instance, discovered automatically to drive provisioning.
- **Dataplane Instance**: One named, Git-declared dataplane, represented by its
  directory and values file, resulting in a running, isolated set of resources in its
  target spoke.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A platform operator brings a new dataplane online by adding exactly one
  directory (one values file) to the dataplanes repository — zero direct cluster
  commands.
- **SC-002**: From the moment a dataplane directory is pushed, its resources are
  observably running in the correct spoke within 2 minutes (assuming the required
  image is already cached in the private registry and on the spoke).
- **SC-003**: 100% of dataplane directories present in the repository correspond to a
  dataplane actually running in its declared spoke, verifiable by inspecting the
  spoke directly.
- **SC-004**: Removing a dataplane's directory results in that dataplane's resources
  being fully removed from its spoke within 2 minutes.
- **SC-005**: Adding an Nth dataplane requires changes to exactly one directory —
  zero changes to any shared file (composition source, package, or discovery
  automation).
- **SC-006**: The composition function's image and source code both remain
  retrievable using only services that run inside this lab, with no outbound
  internet request required after they have been published once.
- **SC-007**: The pre-existing baseline provisioning example (from the original
  composition) continues to pass its own original acceptance scenarios unmodified.

## Assumptions

- This feature is additive: the existing baseline composition and its example remain
  in place and working, and the advanced, Golang-based composition is delivered as a
  second, more capable example alongside it — not a replacement — so the previously
  verified example keeps passing.
- Adopting a composition-function-based (rather than pure patch-and-transform)
  composition model is a deliberate technology change for this platform and requires
  updating the project's recorded technology decisions before implementation
  proceeds; that update happens as part of planning this feature, not within this
  spec.
- The dataplanes repository becomes the standard way to declare dataplane instances
  for the advanced composition going forward; the existing static example claim(s)
  for the baseline composition are left as-is and are not migrated into this
  repository.
- The private registry requires no authentication for pulling images from inside the
  lab's trusted network; if publishing (pushing) requires credentials, those
  credentials are handled the same way other secrets in this platform are (generated
  out-of-band, never committed).
- Automatically building and publishing a new composition-function image on every
  source change (continuous integration) is out of scope for this feature; publishing
  a new image is a manual or scripted step for now, and this gap is called out
  explicitly rather than silently assumed solved.
- A single private registry instance is sufficient; base/tooling images (e.g., the
  language runtime used to build the function) may still come from outside the lab
  at build time — only the resulting function image itself must be served
  internally for normal operation.
- "Dataplane" in this feature refers to the same kind of provisioned workload
  introduced by the original hub-and-spoke provisioning feature; this feature changes
  *how richly* it is composed and *how* it is declared and packaged, not the
  underlying hub-and-spoke delivery model.
