---
title: "Kubernetes STRIDE threat modeling pt.6/6: Elevation of privileges"
date: 2021-05-08T18:36:15+02:00
draft: true
---

Hello everyone, a long time has passed after the 5th part of this journey through STRIDE thread modeling in Kubernetes has been published.
If you recall well, STRIDE is a model of threats for identifying security threats, by providing a mnemonic for security threats in six categories:
Spoofing
Tampering
Repudiation
Information disclosure (privacy breach or data leak)
Denial of service
Elevation of privilege
In this last chapter we'll talk about elevation of privilege. Well, this category can be very wide, but let's start thinking about what can comprise and what we can do against this category of threats.

# Elevation of privilege


Elevation or escalation of privileges is gaining higher access than what is granted. This in turn can be leveraged to access unauthorized resources or to cause damage.
Also, this attack can be conducted through other different types of attacks, like spoofing, where an actor claims to be a different actor with higher privileges, and so on. 

I think we could consider prevention and detection: prevention can be generally done via access control, and detection through analysis of audit events - this assumes we have auditing in place.
In Kubernetes we can think about Role Based Access Control to authorize or not access to Kubernetes resources through roles, but we also have underlying infrastructure resources, in which case we can think about security Context to authorize workload to access operating system resources, like Linux namespaces.

All of this is a bit simplicistic for sure, but just consider this as a starting point for reflections as nothing can be 100% secure, and no solution can exists that can cover all scenarios. 

## Prevention

Prevention is the act to avoid that an action occurs. In this case we're talking about unwanted actions, like for example that a process in a Pod's container 

### Kubernetes

In Kubenetes RBAC is what authorizes or not access to Kubernetes resources to Kubernetes identities through use of roles. The policies that we need are generally specific on the workload that we run, but the recommendation is to follow deny-by-default approach, and to authorize the more minimum set of capabilities as possible.
In detail not using default ServiceAccount and configuring and binding proper Roles is a good choice. I won't go in detail of how to configure RBAC in Kubernetes, but you can take a look [here](https://kubernetes.io/docs/reference/access-authn-authz/rbac/).
At the same time we should consider that also Kubernetes components like kubelet is authorized to access Kubernetes resources like Secrets through [Node Authorization](https://kubernetes.io/docs/reference/access-authn-authz/node/).

### OS

We're no longer talking about granting access to Kubenetes resources to Kubernetes workload, instead we're talking about granting access to OS resources to OS workload, as in the end Pods run as tasks at operating system level.
Here is where all the magic happens, and where our beautiful containers are "composed" through Linux [namespaces](https://man7.org/linux/man-pages/man7/namespaces.7.html), [cgroups](https://www.man7.org/linux/man-pages/man7/cgroups.7.html), [capabilities](https://www.man7.org/linux/man-pages/man7/capabilities.7.html).
In Kubernetes Security Context is what enables or not access to underlying operating system resources to Kubernetes pods.  It can :
define DAC for files based on user and group ids
apply SELinux labels
allow execution as host root
Linux capailities
Running with AppArmor profiles
Syscall filtering via SecComp
Allow privilege escalation by setting (no_new_privs)[https://www.kernel.org/doc/html/latest/userspace-api/no_new_privs.html] flag
Mount rootfs read-only

#### Policy design

When choosing which level of privileges we'd want to allow, let's consider:
- Prevent containers from running as uid 0 in the container user namespace (e.g. `securityContext.runAsUser: 1000`)
- Take into consideration that user namespaces also prevents different Pods to run processes as same user (uid) and potentially causing corruption of the data when accessing the same resources
- Drop capabilities: even with user namespaces, unlikely a container needs all capabilities by running as root, so: run the pod as a non-root user enabling the least needed capabilities (`securityContext.XXXXXXXXXXX`). See more [here](https://lwn.net/Articles/420624/) about Linux capabilities with user namespaces.
- Filtering syscalls: as for capabilities, we can use `seccomp` to filter system calls by using the container's securityContext.
- Preventing privilege escalation: since in Linux by default a child processes is allowed to claim more privileges than the parent, this is not ideal for containers, so use Pod Security Policy to set `allowPrivilegeEscalation: false`.

#### Policy enforcement

What can be used to write and enforce policies and so prevent Pods from running with higher privileges with respect to what we would grant to them is Pod Security Policy feature. It provides API objects to declare policies and a validating and also mutating admission controller to enforce them.
Unfortunately a non-clear path has been drawn in these years letting us with doubts and limits, and leading in the end to [deprecation](https://kubernetes.io/blog/2021/04/06/podsecuritypolicy-deprecation-past-present-and-future) of its APIs from 1.21. A [Kubernetes Enhanched Proposal](https://github.com/kubernetes/enhancements/pull/2582) is in place, that very briefly proposes a simpler approach based on the [Pod Security Standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/) which identifies three basic levels of policies (Privileged, Baseline, Restricted), appliance of them via annotations at Namespace level and enforcement through a new dedicated admission controller.
Keep it mind that it should cover different scenarios and easy the migration from PSP, but at the same time for more advanced use cases there are different framework like [Gatekeeper](https://github.com/open-policy-agent/gatekeeper) that allow us to write fine-grained Rego policies with OPA, but also [Kyverno](https://github.com/kyverno/kyverno/) that instead doesn't require to learn a new language just to name one.
Anyway, always consider that the more complexity we add, the larger the attack surface, so keep it in mind when choosing solutions.

## Detection

### Kubernetes

Kubernetes (static and dynamic) Audit events parsing: XXXXXXXXX

### OS

OS events parsing: Falco, Cilium, XXXXXXXXXXXX

## Known vulnerabilities

Vulnerabilities and mitigations:
- https://info.sysdig.com/XhR0P5Z0E000TP7Ib006QR0
- https://sysdig.com/blog/cve-2020-14386-falco/
