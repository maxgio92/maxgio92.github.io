---
title: "STRIDE threat modeling on Kubernetes pt.6/6: Elevation of privilege"
date: 2021-07-05T14:05:00+02:00
tags: [kubernetes, linux, security]
categories: [kubernetes]
slug: stride-threat-modeling-kubernetes-elevation-of-privileges
draft: false
---

Hello everyone, a long time has passed after the 5th part of this journey through STRIDE thread modeling in Kubernetes has been published.
If you recall well, STRIDE is a model of threats for identifying security threats, by providing a mnemonic for security threats in six categories:
- Spoofing
- Tampering
- Repudiation
- Information disclosure
- Denial of service
- Elevation of privilege

In this last chapter we'll talk about elevation of privilege. Well, this category can be very wide, but let's start thinking about what it can comprises and what we can do against this category of threats.

# Elevation of privilege


Elevation or escalation of privileges is gaining higher access than what is granted. This in turn can be leveraged to access unauthorized resources or to cause damage.
Also, this attack can be conducted through other different types of attacks, like spoofing, where an actor claims to be a different actor with higher privileges, and so on. 

So the first question we'd like to answer could be: what we can generally do? I think we can consider from an high-level point of view **prevention** and **detection**: prevention can be done via access control, and detection through analysis of audit events - this assumes we have auditing in place.

In Kubernetes Role-Based Access Control authorizes or not access to Kubernetes resources through roles, but we also have underlying infrastructure resources, and Kubernetes provides primitives to authorize workload to access operating system resources, like Linux namespaces.

All of this is a bit simplicistic for sure, but just consider this as a starting point for reflections: nothing can be 100% secure, and no solution can exists that can cover all scenarios. 

## Prevention

Prevention is the act to avoid that an action occurs. In this case we're talking about unwanted actions, like for example that a Pod's container runs with unwanted capabilities like [`CAP_SYS_ADMIN`](https://lwn.net/Articles/486306/).

### Kubernetes

In Kubenetes access control is mostly achieved with usage of [roles](https://kubernetes.io/docs/reference/access-authn-authz/rbac/). The policies that we need are generally specific on the workload that we run, but the recommendation is to follow deny-by-default approach, and to authorize the more minimum set of capabilities as possible.
In detail not using default `ServiceAccount`, configuring and binding [proper permissions](https://kubernetes.io/docs/reference/access-authn-authz/rbac/#service-account-permissions), and do not mound Service Account token when not needed, is a good choice.

At the same time we should consider that also Kubernetes components like `kubelet` is authorized to access Kubernetes resources like `Secrets` through [Node Authorization](https://kubernetes.io/docs/reference/access-authn-authz/node/).
And not only in-cluster authorized requests, but also ones that are authorized externally, like users that are authenticated and authorized by cloud provider/on-premise IAM services through OIDC or SAML flows.

Furthermore, authorized workload runs in the clusters and sometimes can make API requests to Kubernetes. In the era of GitOps we let further workload to reconcile workload as we'd desire. So keep in mind which privileges GitOps controllers need and apply least privileg principle also there. The work that Flux team is doing for [modeling](https://github.com/fluxcd/flux2/pull/582) their API considering complex scenarios like multi-tenancy is great.

Talking about access control in multi-tenancy scenarios [Capsule](https://github.com/clastix/capsule) is an interesting project which can help with managing access control easily.

### OS

We're no longer talking about granting access to Kubenetes resources to Kubernetes workload, instead we're talking about granting access to OS resources to OS workload, as in the end Pods run as tasks at operating system level.
Here is where all the magic happens, and where our containers are composed through Linux [namespaces](https://man7.org/linux/man-pages/man7/namespaces.7.html), [control groups](https://www.man7.org/linux/man-pages/man7/cgroups.7.html), [capabilities](https://www.man7.org/linux/man-pages/man7/capabilities.7.html).

I won't go in details of specific container escape techniques like Kamil Potrec did [here](https://snyk.io/blog/kernel-privilege-escalation/) very well, but I'm talking about general approaches and vectors to consider and which prevention we could do.
In Kubernetes [`SecurityContext`](https://kubernetes.io/docs/tasks/configure-pod-container/security-context/) is what enables or not access to underlying operating system resources to Kubernetes pods.

Access control should be in place also at this level, so basically we'd want policies to prevent unwanted privileges.

#### Policy design

I'm talking about policies in general, beyond the implementation. When choosing which level of privileges we'd want to allow, let's consider:
- Prevent containers from running as **UID 0** in the container user namespace (with `securityContext.runAsUser` or specifying it from `Dockerfile`)
- Drop **capabilities**: even with unprivileged user namespaces, apply [least needed capabilities](https://kubernetes.io/docs/tasks/configure-pod-container/security-context/#set-capabilities-for-a-container). See more [here](https://lwn.net/Articles/420624/) about Linux capabilities with user namespaces.
- Filtering **syscalls**: as for capabilities, we can use `seccomp` to filter system calls by using the container's `securityContext`, for example by blocking common syscalls used in techniques like [`unshare`](https://man7.org/linux/man-pages/man2/unshare.2.html) to create new Linux namespaces or [`userfaultd`](https://man7.org/linux/man-pages/man2/userfaultfd.2.html) to control page faults in userspace after triggering overflows. With this regard, [Security Profiles Operator](https://github.com/kubernetes-sigs/security-profiles-operator) would help to automatically generate initial `seccomp` or `AppArmor` profiles, specific to applications.
- Avoid to attach host **namespaces** unless strictly needed. I found [this](https://github.com/BishopFox/badPods) repo well done to understand it.
- Preventing privilege escalation: since in Linux by default a child processes is allowed to claim more privileges than the parent, this is not ideal for containers, so use Pod Security Policy to set `allowPrivilegeEscalation: false`.

Just a note about unprivileged [user namespaces](https://man7.org/linux/man-pages/man7/user_namespaces.7.html) and Kubernetes: starting in Linux 3.8, unprivileged processes can create user namespaces, and the other types of namespaces can be created with just the `CAP_SYS_ADMIN` capability in the caller's user namespace (Kinvolk explains clearly how it relates to containers [here](https://kinvolk.io/blog/2020/12/improving-kubernetes-and-container-security-with-user-namespaces/)).
 [Rootless containers](https://rootlesscontaine.rs) are [based](https://rootlesscontaine.rs/how-it-works/userns/) on that, unfortunately Kubernetes doesn't already [support](https://github.com/kubernetes/enhancements/pull/2101) them, but Akihiro Suda is pushing effort on his work in progress to have a "rootless Kubernetes" distribution, which is [`Usernetes`](https://github.com/rootless-containers/usernetes). So, let's try it and give feedbacks!

#### Policy enforcement

What can be used to write and enforce policies and so prevent Pods from running with higher privileges with respect to what we would grant to them is Pod Security Policy feature. It provides API objects to declare policies and a validating and also mutating admission controller to enforce them.

Unfortunately a non-clear path has been drawn in these years letting us with doubts and limits, and leading in the end to [deprecation](https://kubernetes.io/blog/2021/04/06/podsecuritypolicy-deprecation-past-present-and-future) of Pod Security Policy APIs from 1.21. A [KEP](https://github.com/kubernetes/enhancements/pull/2582) is in place, that very briefly proposes a simpler approach based on the [Pod Security Standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/) which identifies three basic levels of policies (`Privileged`, `Baseline`, `Restricted`), appliance of them via annotations at Namespace level and enforcement through a new dedicated admission controller.

Keep it mind that it should cover different scenarios and easy the migration from PSP, but at the same time for more advanced use cases there are different framework like [Gatekeeper](https://github.com/open-policy-agent/gatekeeper) that allow us to write fine-grained Rego policies with OPA, but also [Kyverno](https://github.com/kyverno/kyverno/) that instead doesn't require to learn a new language just to name one.
Another option is [Polaris](https://github.com/FairwindsOps/polaris), which offers admission controllers that prevents also on this.

Anyway, always consider that for sure the more powerful the solution the higher the granularity and probability to tailor our scenarios, but also IMHO:
- the more complexity we add, the larger could be the attack surface;
- the steeper the learning curve, the harder could be the effectiveness to be achieved.

### Network

Don't forget to think about the network, as also network resources can be used to escalate, such as by getting informations from cloud provider's metadata API. [`NetworkPolicies`](https://kubernetes.io/docs/concepts/services-networking/network-policies/) enables to do access control at network level. 
[Kinvolk](https://kinvolk.io/)'s Inspektor Gadget [network-policy](https://github.com/kinvolk/inspektor-gadget/blob/master/docs/guides/network-policy.md) gadget could help to generate our Network Policy by inspecting our Pods network activity. Then the [Network Policy Editor](https://editor.cilium.io/) by [Cilium](https://cilium.io/) can also teach and generate them.

## Detection

### Kubernetes

Kubernetes provides auditing features through [dedicated APIs](https://kubernetes.io/docs/reference/config-api/apiserver-audit.v1/). Audit [`Events`](https://kubernetes.io/docs/reference/config-api/apiserver-audit.v1/#audit-k8s-io-v1-Event) are events that are recorded by the API server as defined for [`Policy`](https://kubernetes.io/docs/reference/config-api/apiserver-audit.v1/#audit-k8s-io-v1-Policy) and sent to [backends](https://kubernetes.io/docs/tasks/debug-application-cluster/audit/#audit-backends).
From the [decision on removal](https://groups.google.com/g/kubernetes-sig-auth/c/aV_nXpa5uWU) of the dynamic backend feature, there's a [proposal](https://docs.google.com/document/d/16cy_ZD94ooBAvlH-rFOel8RPDWRiGFg4Cz11l4sfEII/edit) on introducing a `DynamicAudit Proxy` based on static webhook, so this last one remains the fundamental feature to base on.


### OS

Auditing at the operating system level can be looked at by inspecting the requests that the containers (and not only) can fire to interact with the OS, so the system calls. [Falco](https://falco.org) is one of the projects that does exactly that, by capturing, inspecting the fired syscalls and filtering the suspictious ones. Alerts can can be shipped to webhook endpoints and with the addition of [Falco Sidekick](https://github.com/falcosecurity/falcosidekick) to a lot of backends like object storage services or message queues or chats.
Then, also mitigation can be triggered from detection events in Falco, for example [with Kubeless](https://falco.org/blog/falcosidekick-reponse-engine-part-1-kubeless/).

For sure here eBPF plays a fundamental role here as it allow to program the kernel in a safe manner and easily inspect kernel events.

[Inspektor Gadget](https://github.com/kinvolk/inspektor-gadget) is a collection of tools to do inspection inspired by [kubectl-trace](https://github.com/iovisor/kubectl-trace) plugin which schedules [bpftrace](https://github.com/iovisor/bpftrace) programs in Kubernetes clusters. The most relevant gadget for this scope is the [traceloop](https://github.com/kinvolk/traceloop) that can help inspecting system calls requested by Pods also in the past.
Here what is very interesing is also the [capabilities](https://github.com/kinvolk/inspektor-gadget/blob/master/docs/guides/capabilities.md) gadget that can help to tailor our Pod container's `SecurityContext`s.
What we'd need then is a filtering layer that can fill an alert system for suspictious behaviour.

## Known vulnerabilities

Now that we reason about some possible vectors, let's list known vulnerabilities from which we can defend with detection and prevention.

### [CVE-2020-14386](https://cve.mitre.org/cgi-bin/cvename.cgi?name=CVE-2020-14386)

In a couple of words, this can be exploited with kernels before 5.9-rc4. As this privilege escalation work using raw sockets and by default Kubernetes adds `CAP_NET_RAW` capabilities to the pods, As you may guess, a `PodSecurityPolicy` that drops this capability can work. But I recommend to dig into it.

See [here](https://sysdig.com/blog/cve-2020-14386-falco/) how to detect and mitigate with Falco.

### [CVE-2020-8559](https://cve.mitre.org/cgi-bin/cvename.cgi?name=CVE-2020-8559)

The API server in versions from v1.6 to v1.15 and prior to v1.16.13, v1.17.9 and v1.18.6 are vulnerable to an unvalidated re-direct on proxied upgrade requests that could allow an attacker to escalate privileges from a node compromise to a full cluster compromise. So, let's keep Kubernetes up-to-date.

Also, we can leverage a tool to hunt on our cluster for weaknesses, which is [kube-hunter](https://github.com/aquasecurity/kube-hunter). You can run it on an external machine or within the cluster on the machine or in a pod.

## Conclusion

So we talk about what privilege escalation is, which are the resources that we should protect, both when we do prevention and when we do detection.

## Another conclusion

As we go through this journey I learnt a lot of stuff that was new to me. When preparing this part and re-reading the first ones I thought: "What is this? Was it me? I should not publish this", and I was going to delete and re-write them. I saw a very different approach, a different consciousness and confusion of what I was talking about.

But I thought that this is part of our journey. And I let them published with pride.

What I'm tying to say, is that we have **another conclusion**. No one will know everything and we **always** are in a continuous **journey**.
We have a lot of value in sharing what we learn and our thoughts. This is why I opened this blog, because I believe in it.

So.. Let's keep in touch here, on Twitter, Github or anywhere you want!
