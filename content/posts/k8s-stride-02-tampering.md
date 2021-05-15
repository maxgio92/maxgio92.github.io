---
title: "STRIDE threat modeling on Kubernetes pt.2/6: Tampering"
date: 2020-02-11T18:36:15+02:00
tags: [kubernetes, security]
categories: [kubernetes]
draft: false
---

In the previous post of this little series we talked about preventing spoofing on Kubernetes. Today we'll talk about the T of STRIDE: **Tampering**.

Tampering is the act of changing something in a malicious way, to gain extra privileges or for denial of service.

Generally for preventing tampering is important to:
- limit the access to critical components;
- control the access to critical components;

Furthermore, it's important to watch for evidence of tampering.

Generally, a common solution to highlight instances of tampering could be using seals, but let's apply these concepts to the Kubernetes world.

# Limit access

## Control plane

To protect data at rest, [restrict access](https://kubernetes.io/docs/tasks/administer-cluster/securing-a-cluster/#controlling-access-to-the-kubernetes-api) to master nodes to protect data on etcd. Furthermore, [encrypt](https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/) etcd data, especially Secrets.

To protect data in transit, TLS guarantees privacy besides integrity.
The communication from the cluster to the API Server is TLS-encrypted (see here to secure traffic to the API Server).

## Data plane

From the developer perspective - even if the line is not so clear - set containers root filesystem to read-only using SecurityContexts, at container or pod level, since the data that needs to be written is usually persisted through volumes:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: my-secure-pod
spec:
  containers:
  # ...
  securityContext:
    readOnlyRootFilesystem: true
    # ...
```

From the administrator perspective, the best defense against data tampering is to validate data before processing it. For example the vulnerability [CVE-2019–11253](https://cve.mitre.org/cgi-bin/cvename.cgi?name=CVE-2019-11253) was found last year and this is the [related issue](https://github.com/kubernetes/kubernetes/issues/83253) on GitHub, there are also described recommended mitigation actions.

You can validate pods through [Pod Security Policies](https://kubernetes.io/docs/concepts/policy/pod-security-policy/). They are implemented as an additional [Admission Controller](https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/#podsecuritypolicy) and you can prevent for:
- creating Pods with non read only root filesystems:
  ```yaml
  
  apiVersion: policy/v1beta1
  kind: PodSecurityPolicy
  metadata:
    name: my-psp-ro-rootfs
    # ...
  spec:
    # ...
    readOnlyRootFilesystem: false
    # ...
  ```
- creating Pods that access host filesystem to not allowed paths through hostPath volumes, by specifying a whitelist of host paths that are allowed to be used by hostPath volumes:
  ```yaml
  apiVersion: policy/v1beta1
  kind: PodSecurityPolicy
  metadata:
    name: my-psp-hostpaths
    # ...
  spec:
    # ...
    allowedHostPaths:
      - pathPrefix: "/example"
        readOnly: true
    # ...
  ```

**Important**: Remember to authorize the policies before enabling the Pod Security Policy admission controller, otherwise it will prevent any pods from being created in the cluster. See [here](https://kubernetes.io/docs/concepts/policy/pod-security-policy/#authorizing-policies) to know how to do it.

Other than PSP you can configure [Open Policy Agent](https://www.openpolicyagent.org/docs/latest/kubernetes-introduction/) that is an open source, general-purpose policy engine that unifies policy enforcement; [OPA GateKeeper](https://kubernetes.io/blog/2019/08/06/opa-gatekeeper-policy-and-governance-for-kubernetes/) integrates OPA with Kubernetes.

### Application

Restrict access to the container images' registry. For example, on AWS you can enforce IAM policies on ECR repositories.

### Configuration

Restrict access to the repositories of the configuration files. It can be obvious but do not store sensitive data on repositories, instead use Secrets. Moreover, evaluate if you need a secrets manager such as [Vault](https://www.vaultproject.io/); you can use it to [inject Secrets](https://www.hashicorp.com/blog/injecting-vault-secrets-into-kubernetes-pods-via-a-sidecar) through sidecars.

# Control access

[Enable auditing](https://kubernetes.io/docs/tasks/debug-application-cluster/audit/) on Kubernetes binaries. Furthermore, you can leverage additional security solutions like [Falco](https://falco.org/), an [eBPF-powered](https://sysdig.com/blog/sysdig-and-falco-now-powered-by-ebpf/) OSS for cloud native runtime security that is now part of the CNCF.

I recommend to see [this session](https://asciinema.org/a/246326) to see how it can capture potentially abnormal system events through its set of [rules](https://falco.org/docs/examples/) and send them to its audit endpoint through Kubernetes [Webhooks](https://kubernetes.io/docs/reference/access-authn-authz/webhook/).

It can be installed standalone or as a DaemonSet; follow [this guide](https://falco.org/docs/installation/) to know how to install and use it.

# Watch for evidence of tampering

Verify downloaded binaries for the container runtime by running SHA-2 checksum. For the purpose of the conciseness of this post I don't talk about it here, but you can read this simple [howto](https://linuxconfig.org/how-to-verify-checksums-in-linux).

That's all for this part, thank you and stay tuned for the next one.

Happy hacking!
