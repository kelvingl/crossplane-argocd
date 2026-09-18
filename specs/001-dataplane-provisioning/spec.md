# Feature Specification: Hub-and-Spoke Dataplane Provisioning

**Feature Branch**: `001-dataplane-provisioning`

**Created**: 2026-09-18

**Status**: Draft

**Input**: User description: "Provisionamento de dataplanes via modelo hub-and-spoke: um operador do hub cria um claim DataPlane (XRD XDataPlane) escolhendo um spoke (spoke-01 ou spoke-02) e parâmetros (imagem, réplicas); o Crossplane, rodando no hub, usa provider-kubernetes com o ProviderConfig do spoke escolhido para provisionar Namespace + Deployment + Service diretamente naquele cluster spoke, sem que o spoke rode nenhum controlador Crossplane próprio. Documentar retroativamente o que já foi implementado em crossplane/compositions, crossplane/config e crossplane/examples."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Provision a workload into a chosen spoke (Priority: P1)

An operator working from the hub declares a single request naming which spoke
(dataplane) should receive a new workload. Without touching the spoke directly, the
workload — a namespace, a running application, and a way to reach it — appears in
that spoke cluster.

**Why this priority**: This is the entire point of the hub-and-spoke model: a single
control point in the hub provisions real resources on remote dataplanes. Without
this, there is no lab to demonstrate.

**Independent Test**: Create one request naming `spoke-01`, then confirm — by
inspecting `spoke-01` directly — that a namespace, an application, and a way to
reach it now exist there, and that `spoke-02` was untouched.

**Acceptance Scenarios**:

1. **Given** `spoke-01` is registered with the hub, **When** an operator requests a
   dataplane workload targeting `spoke-01`, **Then** a namespace, a running
   application, and a reachable service appear in `spoke-01` only.
2. **Given** a request has already been provisioned successfully, **When** the
   operator inspects the request's status from the hub, **Then** the hub reports
   whether provisioning succeeded, without the operator needing direct access to the
   spoke.

---

### User Story 2 - Customize the provisioned workload (Priority: P2)

An operator picks which container image runs and how many replicas it should have,
instead of always getting a fixed default workload.

**Why this priority**: A hardcoded workload only proves connectivity once; letting
operators vary the image and scale is what makes the model reusable for more than
one demo.

**Independent Test**: Create two requests targeting the same spoke with different
images and replica counts, and confirm each spoke workload reflects its own request's
values independently.

**Acceptance Scenarios**:

1. **Given** an operator does not specify an image or replica count, **When** the
   request is provisioned, **Then** the workload runs with documented default values.
2. **Given** an operator specifies a custom image and a replica count of 2, **When**
   the request is provisioned, **Then** the spoke workload runs that exact image with
   2 replicas.

---

### User Story 3 - Add a new spoke without changing the provisioning logic (Priority: P3)

A platform operator registers an additional spoke cluster, and existing/new
dataplane requests can target it, without editing the composition or the resource
definition that describes what a dataplane request looks like.

**Why this priority**: Proves the model scales past the two spokes shipped in this
lab; it is the difference between a one-off demo and a repeatable pattern, but the
lab is already useful without a third spoke on day one.

**Independent Test**: Register a new spoke by adding only a new spoke credential and
its corresponding registration entry, then create a request naming that new spoke and
confirm the workload appears there — with no change to the composition or resource
definition files.

**Acceptance Scenarios**:

1. **Given** a new spoke cluster and its credentials, **When** a platform operator
   registers it following the existing pattern, **Then** requests can target the new
   spoke by name with no other change required.

---

### Edge Cases

- What happens when a request names a spoke that has no matching registration? The
  request MUST surface a clear failure/error status rather than silently succeeding
  or being provisioned to the wrong spoke.
- What happens when two separate requests are created for the same spoke? Each
  MUST get its own isolated namespace in that spoke so their workloads never collide,
  even if the requests share the same image/replica settings.
- What happens when the target spoke is temporarily unreachable at request time? The
  request MUST keep retrying and converge to "provisioned" once the spoke becomes
  reachable again, rather than failing permanently.
- What happens when a request is deleted? The namespace and workload it created in
  the spoke MUST be removed from that spoke as well.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST let an operator, acting only against the hub, declare
  which registered spoke should receive a new dataplane workload.
- **FR-002**: System MUST provision an isolated namespace, a running application, and
  a way to reach it inside the selected spoke, without requiring any provisioning
  component to run on the spoke itself.
- **FR-003**: System MUST let the operator customize the workload's container image
  and replica count per request, and MUST apply documented defaults when either is
  omitted.
- **FR-004**: System MUST keep workloads from different requests isolated from one
  another even when they target the same spoke (no name or namespace collisions).
- **FR-005**: System MUST report, from the hub, whether a request's resources were
  successfully created in the target spoke.
- **FR-006**: System MUST support registering additional spokes without modifying the
  definition of what a dataplane request looks like or how it is provisioned.
- **FR-007**: System MUST remove a request's provisioned namespace and workload from
  the spoke when the request itself is removed from the hub.

### Key Entities

- **Dataplane Request**: Represents one operator-declared intent to run a workload on
  a specific spoke. Key attributes: target spoke name, container image, replica
  count, and a status indicating whether provisioning succeeded.
- **Spoke Registration**: Represents one dataplane cluster made available as a
  provisioning target, identified by name and holding the credentials needed to reach
  it. Independent of any specific Dataplane Request.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: From the moment a dataplane request is created, its workload is
  observably running in the correct spoke within 2 minutes (assuming the container
  image is already cached on that spoke).
- **SC-002**: Retargeting a workload to a different registered spoke requires
  changing exactly one field on the request.
- **SC-003**: 100% of dataplane requests created against a registered spoke result in
  a namespace, application, and reachable service that actually exist in that spoke,
  verifiable by inspecting the spoke directly.
- **SC-004**: Onboarding an additional spoke requires adding a credential and a
  registration entry only — zero changes to the files that define what a dataplane
  request looks like or how it is provisioned.
- **SC-005**: Two dataplane requests targeting the same spoke never overwrite or
  interfere with each other's namespace, application, or service.

## Assumptions

- This lab pre-registers two spokes (`spoke-01`, `spoke-02`); onboarding additional
  spokes follows the same registration pattern described in User Story 3.
- The provisioned workload is a generic HTTP demo application standing in for a real
  dataplane workload — the model is about *where* and *how* something gets
  provisioned, not about what the workload does.
- Operators interact by declaring requests directly against the hub (no dedicated UI
  or self-service portal is in scope for this feature).
- Network connectivity from the hub to each registered spoke's control plane already
  exists by the time a spoke is registered; establishing that connectivity is covered
  by spoke onboarding, not by this feature.
