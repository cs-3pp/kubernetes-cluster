# How CloudSigma Operators Access the Managed-K8s Service

This page is the customer-trust reference for what CloudSigma's platform operators *can* do, *how* they do it, and where every action is recorded. Read this if you need to answer:

- Who can log in to the platform that hosts my cluster's control plane?
- How are operator credentials stored, rotated, and revoked?
- Are operator actions auditable and tied to a real person?
- What's the emergency-access path, and is it the same as the day-to-day path?
- Where exactly does my cluster end and the operator-controlled platform begin?

The short answer: **every operator action goes through one of two narrowly-scoped paths** (day-to-day OIDC SSO with per-person audit; emergency break-glass with rotated shared identity), every platform-config change is reviewed in a Git repository with cryptographically-signed commit history, every secret committed to that repository is **encrypted at rest** with a small set of authorized recipients, and the entry point into the platform's private network is a single bastion host with **public-key-only** SSH.

> **Audience.** You manage your cluster through the CloudSigma marketplace UI and use the downloaded `kubeconfig` for `kubectl`. You do **not** see, touch, or have credentials for the management platform that hosts your cluster's control plane — but you may need to confirm how that platform is operated for your own compliance or security review. This page describes the operator-side controls so you can audit them.

---

## TL;DR — the four layers

1. **Bastion host = the only network entry.** The management platform's control-plane nodes have **no public IPs**. The only public-IP node in front of them is a single bastion VM with SSH key-only auth (passwords disabled) and no other ingress ports open. Operators reach the platform only by SSH-ing through this bastion.

2. **GitOps repository = the only config-change path.** All platform configuration — Helm release versions, secrets, RBAC bindings, image tags, network firewall rules — is declared in a private Git repository (the *platform fleet*). The platform's Flux controllers continuously reconcile from that repository's `main` branch. **No operator ever runs ad-hoc `kubectl apply` against the platform.** Every change is a PR with review history.

3. **SOPS + age = encryption at rest in Git.** Every file in the fleet repository whose name ends in `.enc.yaml` is encrypted with [SOPS](https://github.com/getsops/sops) using [age](https://age-encryption.org/) public-key recipients. Plaintext secrets — break-glass kubeconfigs, Docker Hub pull tokens, CloudSigma API credentials, customer-VLAN secrets — never exist in plaintext on disk except inside a pod's tmpfs after Flux decrypts them in-cluster. The list of authorized decryption keys is itself committed in plaintext (`.sops.yaml`); rotating a key requires re-encrypting every file with the new list, which leaves an obvious audit trail in Git.

4. **OIDC SSO + break-glass = two access tiers.** Day-to-day operator access uses Keycloak SSO with a per-engineer email recorded in every audit log entry — no shared service-account tokens. The break-glass kubeconfig (a single static `cluster-admin` token in the fleet repository) exists for one purpose only: recovering when SSO itself is broken. The break-glass token is **rotated after every use** and the rotation is itself a Git commit.

---

## 1. The bastion host — single network entry

Each CloudSigma region runs one bastion VM in front of the management cluster:

```
                            ┌──────────────────────────────────────┐
                            │  CloudSigma region (e.g. zrh)         │
                            │                                       │
   Operator workstation     │  ┌─────────────────────────────────┐  │
   ─────────────────────────┼─►│ Bastion VM                      │  │
   ssh ubuntu@<public-IP>   │  │  ─ public IP (one per region)   │  │
   (SSH key only)           │  │  ─ SSH key-only (passwords off) │  │
                            │  │  ─ NAT gateway to private VLAN  │  │
                            │  │  ─ NO other ports exposed       │  │
                            │  └────────────────┬────────────────┘  │
                            │                   │                   │
                            │  ┌────────────────┴───────────────┐   │
                            │  │ Private VLAN (192.168.0.0/23)  │   │
                            │  │  ─ no public IPs               │   │
                            │  │  ─ control-plane nodes:        │   │
                            │  │      master-0, master-1, m-2   │   │
                            │  │  ─ worker nodes                │   │
                            │  │  ─ apiserver (your cluster's   │   │
                            │  │    control plane lives here)   │   │
                            │  └────────────────────────────────┘   │
                            └───────────────────────────────────────┘
```

What the bastion does:

| | |
|---|---|
| **Ingress** | SSH (port 22), key-only authentication, no password fallback. The list of authorized public keys is baked into the bastion's cloud-init and tracked in the platform's Terraform repository — adding a new operator is a Terraform change with PR review. |
| **Egress / NAT** | NAT gateway for private masters/workers to reach the internet (image pulls, OS updates). Without this, the private VLAN is air-gapped from the internet. |
| **Other ports** | None. No HTTP, no RDP, no VNC over the public IP. VNC for OOB recovery exists but uses a randomly-generated 12-character password held by the CloudSigma operator account, not exposed on the bastion's public IP. |

What the bastion does **not** do:

- It is **not** a Kubernetes node. The apiserver does not run on the bastion. Your cluster's data does not flow through it. The bastion only hosts SSH + NAT.
- It is **not** the source of truth for what runs on the platform. That is the fleet repository (next section). The bastion is just the network entry.

If the bastion is compromised, the attacker would still need (a) decryption keys to read any SOPS-encrypted secret in the fleet repository and (b) a valid OIDC token tied to a real operator email to write to the platform. We treat the bastion as a **public-facing surface to be hardened**, not as a trust boundary.

---

## 2. The fleet repository — single source of truth for platform config

Every operator-controlled aspect of the platform lives in one private Git repository (the *platform fleet*):

```
<platform-fleet>/
├── bootstrap/         # One-time install scripts (CNI, Flux, CAPI)
├── infrastructure/    # CNI, cert-manager, gateway, storage  (shared across clusters)
├── platform/          # monitoring, identity provider, control-plane host, virtualization, the managed-K8s controller
├── addons/            # Optional per-cluster: MetalLB pools, S3 storage, marketplace SSO
├── clusters/
│   ├── <region-A>/    # one folder per region
│   └── <region-B>/    # ...
│       ├── cluster-config.env             (plaintext — image tags, network CIDRs)
│       ├── secrets.enc.yaml               (SOPS-encrypted — platform secrets)
│       ├── break-glass-kubeconfig.enc.yaml (SOPS-encrypted — break-glass identity)
│       ├── dockerhub.enc.yaml             (SOPS-encrypted — image-pull token)
│       └── addons/cloudsigma-secrets.enc.yaml (SOPS-encrypted — CloudSigma API token)
└── scripts/
```

How a change reaches your cluster's platform:

1. An operator opens a pull request against `main`.
2. Another platform engineer reviews and approves.
3. The PR is merged. The merge commit is signed and lands on `main`.
4. **Flux** (running inside the management cluster, no external trigger needed) detects the new commit within ~1 minute, pulls it, validates it against its cluster-scoped RBAC, and applies the resulting Kubernetes objects.
5. SOPS-encrypted files are decrypted **inside the cluster** by Flux's SOPS controller, using age private keys held in a Kubernetes Secret in the `flux-system` namespace (mounted only into the SOPS controller's Pod). Plaintext never lands on the operator's workstation.

What this gives you as a customer:

- **No ad-hoc kubectl on the platform.** An operator who tries to `kubectl apply -f my-thing.yaml` against the management cluster outside the fleet is overwritten by Flux on the next reconcile (typically <1 minute). The fleet repository is authoritative.
- **A complete audit trail.** Every change to the platform — including configuration changes that touch your cluster's control-plane parameters — exists as a Git commit with author email and review history.
- **Reproducibility / disaster-recovery.** The platform can be rebuilt from the fleet repository alone. The actual cluster state lives in etcd, but the *configuration* that drives the platform is fully described in Git.

---

## 3. SOPS + age — secrets at rest in Git

Plaintext secrets cannot be committed to the fleet repository. Every file matching `*.enc.yaml` is encrypted with SOPS using age public-key recipients. The encryption configuration is committed in plaintext (`.sops.yaml`):

```yaml
creation_rules:
  - path_regex: '\.enc\.yaml$'
    encrypted_regex: '^(data|stringData)$'
    age: 'age10mskwx065akee5mw4txeqtnn90t724phdzx9k4jxnrgcp9cces6sqfkwvu,age1fugkeh0yhf56d6t2qm8gwqdl3kx7963wv2qq5jax2kewldsfeqgq6p67pm,age16nk3t6chcrjntd76s3an32hx3p2y5cup7vnkywny0uy9gn0tkcuqxzav8s'
```

Three things to notice:

- **Only `data` and `stringData` fields are encrypted.** `apiVersion`, `kind`, `metadata` stay plaintext so kustomize and Flux can parse the file as a Kubernetes resource without decrypting. The actual secret payload — passwords, tokens, certificates — is unreadable.
- **The list of authorized decryption keys is committed in plaintext.** It is a *public* list of age public keys. The corresponding *private* keys live (a) on a small number of platform engineer workstations, in hardware-backed keystores where possible, and (b) inside the management cluster's `flux-system` namespace, mounted only into Flux's SOPS controller.
- **Rotating a key is observable in Git.** If the recipient list changes, every `*.enc.yaml` file in the repository must be re-encrypted to the new list — that's a large multi-file commit that anyone with read access to the fleet repository can see.

What an encrypted file looks like in Git — the apiVersion/kind/metadata stay readable, the actual secret material is opaque AES-256-GCM ciphertext:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: dockerhub
  namespace: kube-dc
type: kubernetes.io/dockerconfigjson
data:
    .dockerconfigjson: ENC[AES256_GCM,data:HFw3...,iv:...,tag:...,type:str]
sops:
    age:
        - recipient: age10mskwx065akee5mw4txeqtnn90t724phdzx9k4jxnrgcp9cces6sqfkwvu
          enc: |
            -----BEGIN AGE ENCRYPTED FILE-----
            ...
            -----END AGE ENCRYPTED FILE-----
        - recipient: age1fugkeh0yhf56d6t2qm8gwqdl3kx7963wv2qq5jax2kewldsfeqgq6p67pm
          enc: |
            ...
            -----END AGE ENCRYPTED FILE-----
    ...
```

Threat model:

| Threat | Mitigated? |
|---|---|
| Someone with read-only access to the fleet repository (e.g. mirror, leaked snapshot) | ✅ Sees ciphertext only. Needs at least one age private key to decrypt. |
| A compromised platform engineer's laptop with their age private key | ⚠️ Has the same secrets as the engineer. Mitigated by laptop full-disk encryption + hardware-backed keystore for the age key + rapid key rotation if a laptop is suspected compromised. |
| A malicious commit that silently drops the encryption (`data: $plaintext`) | ⚠️ Caught by review (PR approval is required). Additional CI lint rejects PRs that introduce plaintext `data` fields in files matching the regex. |
| Flux's SOPS controller compromised | ❌ The controller can decrypt every fleet secret — that's its job. Mitigated by Pod-level isolation, no service-account permissions outside the SOPS controller namespace, audit logs on every Secret access. |

---

## 4. Operator access to your cluster's apiserver — OIDC + break-glass

The platform that hosts your cluster's control plane has its own apiserver (separate from your tenant cluster's apiserver). Operator access to that platform apiserver has two tiers:

### 4a. Day-to-day: OIDC SSO via Keycloak

```
   Operator's laptop                            Management cluster
   ────────────────                             ──────────────────
                                                ┌──────────────────────┐
   `<platform-cli> login --admin`               │ Keycloak             │
   (the operator CLI) ── 1. opens browser ─────►│  master realm        │
                                                │  → admin group       │
                                                │                      │
                  ◄── 2. JWT (15 min lifetime) ─┤                      │
                                                └──────────────────────┘
                  ─── 3. kubectl with JWT ─────►┌──────────────────────┐
                                                │ Apiserver            │
                                                │  ─ OIDC validates JWT│
                                                │  ─ admin group →     │
                                                │    cluster-admin RBAC│
                                                │  ─ audit log records │
                                                │    operator's email  │
                                                └──────────────────────┘
```

The daily-driver chain has exactly three components:

> **one** Keycloak group (`admin` in master realm) → **one** Kubernetes group (`platform:admin`) → **one** `ClusterRoleBinding` (binds `platform:admin` to `cluster-admin`).

To grant an operator admin access, exactly one thing changes: their Keycloak user is added to the `admin` group. No per-engineer commit to the fleet repository, no per-engineer kubeconfig handed out, no shared password. When the operator runs their admin-login command, the apiserver validates their JWT, sees the `admin` group claim, applies `cluster-admin` RBAC, and **records their email** in the audit log.

To revoke an operator: remove them from the Keycloak group. Their JWT becomes invalid at the next refresh (≤15 min); no follow-on commit needed.

What the audit log records on every operator action: who (email), what (HTTP verb + Kubernetes resource), when (timestamp), where (source IP), and the response code. Audit logs are retained on the management cluster's apiserver and shipped to long-term storage (a separate piece of platform infrastructure with operator-only read).

### 4b. Break-glass: when SSO itself is broken

OIDC can fail. Keycloak can be down, the gardener `oidc-webhook-authenticator` Pod can be unreachable, the master realm can be misconfigured. For those situations, the fleet repository carries one file per cluster:

```
clusters/<cluster>/break-glass-kubeconfig.enc.yaml
```

This is a SOPS-encrypted kubeconfig holding a static `cluster-admin` token bound to a Kubernetes ServiceAccount `break-glass` in the `kube-system` namespace. The token does **not** go through OIDC; the apiserver authenticates it as the ServiceAccount, and the audit log records the shared identity `system:serviceaccount:kube-system:break-glass`, NOT the operator's email.

Three properties make this safe:

- **You can't use it without the age private key.** Decrypting `break-glass-kubeconfig.enc.yaml` requires SOPS decrypt with one of the authorized age private keys (§3). An operator who doesn't have an age key can't use break-glass.
- **It's rotated after every use.** The operator CLI that emits the break-glass shell prints a red banner reminding the operator to run the break-glass `rotate` command afterward, which invalidates the token used during recovery and writes a new encrypted token to the fleet repository. That rotation is itself a commit — visible to anyone with fleet read access.
- **It's the deliberate exception, not the rule.** Every use of break-glass leaves a Git commit (the post-recovery rotation) AND an audit log entry on the apiserver (with the shared identity). Both are reviewable. The expectation is "break-glass should be very rare and very visible" — not "break-glass for convenience because OIDC is slow".

### 4c. Who can DECRYPT the break-glass kubeconfig?

A small number — single digits — of platform engineers hold age private keys. Their public keys are listed in `.sops.yaml` (committed in plaintext). To add or remove an engineer:

1. Update `.sops.yaml` with the new recipient list.
2. Re-encrypt every `*.enc.yaml` in the fleet repository with the new list (`sops updatekeys` does this; the commit shows every encrypted file touched).
3. PR review + merge.

A removed engineer can no longer decrypt new versions of secrets, but they retain the OLD versions on their laptop — which is why we also rotate the underlying secrets (database passwords, API tokens, the break-glass token) whenever an operator leaves.

---

## 5. Operator workstation — what tools they use

A platform engineer who passes through the bastion and obtains an OIDC JWT runs a normal `kubectl` against the management cluster's apiserver. Heavy tooling (`kubectl`, `k9s`, `flux`, `sops`, `age`, `helm`, `kustomize`, `kubevirt-virtctl`) is installed on the engineer's laptop directly — no shared admin VM, no shared toolbox.

For emergency in-cluster debugging that would otherwise require pulling tools through the bastion every time, an operator can run a privileged debug Pod with the standard operator toolbox directly in the management cluster — same image used for everyday investigation. The Pod is ephemeral (operator runs it, does their work, deletes it). Every action inside the Pod still hits the apiserver audit log with the operator's identity.

---

## 6. What happens when you (the customer) make a change

Your day-to-day cluster operations — scaling worker pools, upgrading Kubernetes versions, creating Secrets, deploying workloads — do not touch the management platform's apiserver, the bastion, the fleet repository, or operator credentials.

| Your action | Where it goes |
|---|---|
| `kubectl apply -f my-workload.yaml` | Your tenant cluster's apiserver. Doesn't touch the platform. |
| "Scale worker pool" in the marketplace UI | Marketplace API → platform's custom resource for your cluster → platform reconciler provisions/destroys CloudSigma VMs in your account. No operator review needed. |
| "Upgrade control plane" in the marketplace UI | Same path. Platform reconciler bumps the Kubernetes version on your control plane. No operator review needed. |
| "Open a support ticket" | Goes to operators via the marketplace; if a fleet-repository change is needed, an operator opens the PR; PR review is internal and the merge triggers Flux. |

The fleet repository, the bastion, the operator OIDC chain, and the break-glass file are **never** exercised in the course of you operating your own cluster. They are the platform team's mechanism for operating the underlying multi-tenant platform.

---

## 7. Summary — what you can independently verify

| Property | How to verify |
|---|---|
| The bastion accepts SSH key auth only | `nmap` of the bastion's public IP shows port 22 open, nothing else. `ssh -v` to the bastion shows `Authentications that can continue: publickey`. (You won't be able to log in unless your public key is added by an operator.) |
| Operator changes are PR-reviewed | The platform fleet repository shows merge-commit history with reviewer identities. Internal repository, not customer-readable, but available under NDA. |
| Encrypted-at-rest secrets in Git | The `.sops.yaml` recipient list and `*.enc.yaml` ciphertext are visible if you're granted read access to the fleet repository. Without an age private key, the encrypted blobs are unreadable. |
| Operator actions are audited | Audit logs on the management cluster's apiserver record every operator action with their email (OIDC SSO) or shared break-glass identity. Available under NDA. |
| Break-glass is rotated after use | The fleet repository's `git log` against `clusters/<cluster>/break-glass-kubeconfig.enc.yaml` shows one commit per use, with the rotation message. |

For a compliance review where you need to demonstrate that operator access is controlled, audited, and least-privileged, the relevant artifacts are: the `.sops.yaml` file, the fleet repository's commit history, the Keycloak `admin` group membership list, and the apiserver audit log retention configuration. All four are reviewable on request.

---

## References

- [Flux CD — GitOps reconciliation](https://fluxcd.io/)
- [SOPS — Secrets OPerationS](https://github.com/getsops/sops)
- [age — modern file encryption](https://age-encryption.org/)
- [Keycloak — Identity Provider used for operator SSO](https://www.keycloak.org/)
- Related customer-trust documents in this repository: [`encryption-at-rest-design.md`](./encryption-at-rest-design.md) (how your cluster's etcd is encrypted), [`cluster-upgrades.md`](./cluster-upgrades.md) (how worker rollouts work)
