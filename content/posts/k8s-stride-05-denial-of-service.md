---
title: "STRIDE threat modeling on Kubernetes pt.5/6: Denial of service"
date: 2020-09-07T18:36:15+02:00
tags: [kubernetes, security]
categories: [kubernetes]
draft: false
---

I'm back after a long time with the fifth episode of this mini-series about STRIDE threat modeling in Kubernetes.
In the previous one we talked about Information disclosure. This part is about the D that stands for **Denial Of Service**.

DOS is the attempt to making a resource unavailable.
For instance, a Kubernetes dashboard is left exposed on the Internet, allowing anyone to deploy containers on your company's infrastructure to mine cryptocurrency and starve your legitimate applications of CPU ([really happened](https://redlock.io/blog/cryptojacking-tesla) - thanks [Peter](https://dev.to/petermbenjamin)).

Therefore, an induced lack of resources is what generally leads to unavailability.

So, how we can do prevention?
We can do it with:
- Increased Availability
- Resource isolation
- Resource monitoring
- Moreover, vulnerability-specific patches

Now let's jump into Kubernetes world and think about splitting up the different layers on which to guarantee availability:
Nodes
Network
Control plane
Workload

As the availability can be increased on all resources, I'll sum up briefly what we can do.

# Master nodes

- Deploy [multiple master nodes](https://kubernetes.io/docs/tasks/administer-cluster/highly-available-master/) to provide HA on the control plane (for instance to protect from direct attacks to the API server);
- Deploy on multiple datacenters (to protect from attacks on the network to a particular datacenter).

# Worker nodes

- Deploy on multiple datacenters (to protect from attacks on the network to a particular datacenter);
- Configure resource limits per namespace by using [`ResourceQuotas`](https://kubernetes.io/docs/concepts/policy/resource-quotas/) for:
  - CPU and memory;
  - Storage (`PVC` per `StorageClass`);
  - Object count;
  - Extended resources (only limit);

- Configure [resource limits](https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/#requests-and-limits) per container;
  - can also be useful for scheduling purposes with [Pod Priority](https://kubernetes.io/docs/concepts/scheduling-eviction/pod-priority-preemption/), and can be able to define the workload's [Quality of Service](https://kubernetes.io/docs/tasks/configure-pod-container/quality-service-pod/);
  - use [`LimitRanges`](https://kubernetes.io/docs/concepts/policy/limit-range/) to set resource defaults;
- Configure [out of resource handling](https://kubernetes.io/docs/concepts/scheduling-eviction/node-pressure-eviction/) to reclaim resources by notifying [under pressure nodes](https://kubernetes.io/docs/concepts/scheduling-eviction/node-pressure-eviction/#node-conditions) to the `kubelet`;
- Configure [Cluster Autoscaler](https://github.com/kubernetes/autoscaler/tree/master/cluster-autoscaler) to gain availability based on your workload.

# Workload

- Configure [Horizontal Pod Autoscaler](https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/);
- Configure correct [resources limits](https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/) other than requests;
- Configure [Vertical Pod Autoscaler](https://github.com/kubernetes/autoscaler/tree/master/vertical-pod-autoscaler) or [addon-resizer](https://github.com/kubernetes/autoscaler/tree/master/addon-resizer); you can also leverage the VPA in [`Off mode`](https://github.com/kubernetes/autoscaler/tree/master/vertical-pod-autoscaler#quick-start) in order to get only recommendations for setting appropriate resources for your workload;
- Define Pod-to-Pod and Pod-to-external [Network Policies](https://kubernetes.io/docs/concepts/services-networking/network-policies/);
- Configure mutual TLS and proper API authentication mechanism.

# API server

- Configure [high availability](https://kubernetes.io/docs/tasks/administer-cluster/highly-available-master/);
- Configure [monitoring](https://sysdig.com/blog/monitor-kubernetes-api-server/) and alerting on requests and [`Audit`](https://kubernetes.io/docs/tasks/debug-application-cluster/audit/);
- Isolate: do not expose the endpoint on Internet, for instance [syn flood](https://en.wikipedia.org/wiki/SYN_flood) attacks could be in place.

# etcd

- Configure [HA](https://kubernetes.io/docs/tasks/administer-cluster/configure-upgrade-etcd/#multi-node-etcd-cluster);
- Configure [monitoring and alerting](https://sysdig.com/blog/monitor-etcd/) on requests;
- [Isolate](https://kubernetes.io/docs/tasks/administer-cluster/configure-upgrade-etcd/#limiting-access-of-etcd-clusters): so that only the control plane members can access it;
- As a plus, configure [dedicated cluster](https://kubernetes.io/docs/tasks/administer-cluster/configure-upgrade-etcd/#starting-etcd-clusters), since etcd is one of the main bottlenecks and to provide resilience from the other control plane components (e.g. if they are compromised).

# Network

- Configure rate limiting at Ingress Controller level to limit connections and requests per seconds/minute per IP (for example [with NGINX ingress controller](https://kubernetes.github.io/ingress-nginx/user-guide/nginx-configuration/annotations/#rate-limiting));
- Deny source IPs with Network policies.

Then, other than following all the best practices there could also be vulnerabilities on components that we generally consider already secured; so let's sum up a couple of them.

# Known vulnerabilities

## [CVE-2019–9512](https://cve.mitre.org/cgi-bin/cvename.cgi?name=CVE-2019-9512): Ping Flood with HTTP/2

The attacker hammers the HTTP/2 listener with a continuous flow of ping requests. To respond, the recipient start queuing the responses, leading to growing queues and then allocating more memory and CPU.

## [CVE-2019–9514](https://cve.mitre.org/cgi-bin/cvename.cgi?name=CVE-2019-9514): Reset Flood with HTTP/2

The attacker can open several streams to the server and sending invalid data through them.
Having received invalid data, the server sends HTTP/2 `RST_STREAM` frames to the attacker to cancel the "invalid" connection.

With lots of `RST_STREAM` responses, they start to queue.
As the queue gets more massive, more and more CPU and memory get allocated to the application until it eventually crashes.

Kubernetes has released the required patches to mitigate the issues as mentioned above. The new versions were built using the patched versions of Go so that the required fixed are applied to the net/http library.

Fixed versions:
- Kubernetes v1.15.3 - go1.12.9
- Kubernetes v1.14.6 - go1.12.
- Kubernetes v1.13.10 - go1.11.13

## [CVE-2020–8557](https://cve.mitre.org/cgi-bin/cvename.cgi?name=CVE-2020-8557): Node disk DOS

The /etc/hosts file mounted in a pod by kubelet is not included by the kubelet eviction manager when [calculating ephemeral storage](https://kubernetes.io/docs/concepts/scheduling-eviction/node-pressure-eviction/#with-imagefs-1) usage by a pod. If a pod writes a large amount of data to the /etc/hosts file, it could fill the storage space of the node.
Affected versions:
- kubelet v1.18.0–1.18.5
- kubelet v1.17.0–1.17.8
- kubelet < v1.16.13

Fixed Versions:
- kubelet master - fixed by #92916
- kubelet v1.18.6 - fixed by #92921
- kubelet v1.17.9 - fixed by #92923
- kubelet v1.16.13 - fixed by #92924

Prior to upgrading, this vulnerability can be mitigated by using PodSecurityPolicies or other admission webhooks to force containers to drop [`CAP_DAC_OVERRIDE`](https://man7.org/linux/man-pages/man7/capabilities.7.html) or to prohibit privilege escalation and running as root. 

Consider anyway that these measures may break existing workloads that rely upon these privileges to function properly.

## [CVE-2020–8551](https://cve.mitre.org/cgi-bin/cvename.cgi?name=CVE-2020-8551): Kubelet DoS via API

The `kubelet` has been found to be vulnerable to a denial of service attack via kubelet API, including the unauthenticated HTTP read-only API typically served on port 10255, and the authenticated HTTPS API typically served on port 10250.

Affected Versions:
- kubelet v1.17.0 - v1.17.2
- kubelet v1.16.0 - v1.16.6
- kubelet v1.15.0 - v1.15.9

Fixed Versions
- kubelet v1.17.3
- kubelet v1.16.7
- kubelet v1.15.10

In order to mitigate this issue [limit access to the kubelet API](https://kubernetes.io/docs/reference/command-line-tools-reference/kubelet-authentication-authorization/) or patch the kubelet.

## [CVE-2020–8552](https://cve.mitre.org/cgi-bin/cvename.cgi?name=CVE-2020-8552): Kubernetes API Server OOM

The API server has been found to be vulnerable to a denial of service attack via authorized API requests.

Affected Versions:
- kube-apiserver v1.17.0 - v1.17.2
- kube-apiserver v1.16.0 - v1.16.6
- kube-apiserver < v1.15.10

Fixed Versions:
- kube-apiserver v1.17.3
- kube-apiserver v1.16.7
- kube-apiserver v1.15.10

Prior to upgrading, this vulnerability can be mitigated by [preventing unauthenticated or unauthorized access](https://kubernetes.io/docs/concepts/security/controlling-access/) to all apis and by ensuring that the API server automatically restarts if it OOMs.

## [CVE-2019–1002100](https://cve.mitre.org/cgi-bin/cvename.cgi?name=CVE-2019-1002100): Kubernetes API Server JSON-patch parsing

Users that are authorized to make patch requests to the Kubernetes API server can send a specially crafted patch of type [`json-patch`](https://tools.ietf.org/html/rfc6902) (e.g. `kubectl patch - type json` or `Content-Type: application/json-patch+json`) that consumes excessive resources while processing, causing a denial of service on the API server.

Affected versions:
- Kubernetes v1.0.x-1.10.x
- Kubernetes v1.11.0–1.11.7
- Kubernetes v1.12.0–1.12.5
- Kubernetes v1.13.0–1.13.3

Fixed Versions:
- Kubernetes v1.11.8
- Kubernetes v1.12.6
- Kubernetes v1.13.4

Prior to upgrading, this vulnerability can be mitigated by removing patch permissions from untrusted users.

## [CVE-2019–11253](https://cve.mitre.org/cgi-bin/cvename.cgi?name=CVE-2019-11253): Kubernetes API Server JSON/YAML parsing

This is a vulnerability in the API server, allowing authorized users sending malicious YAML or JSON payloads to cause kube-apiserver to consume excessive CPU or memory, potentially crashing and becoming unavailable.

Prior to v1.14.0, default RBAC policy authorized anonymous users to submit requests that could trigger this vulnerability.

Clusters upgraded from a version prior to v1.14.0 keep the more permissive policy by default for backwards compatibility.
Here you can find the more restrictive RBAC rules that can mitigate the issue.

Affected versions:
- Kubernetes v1.0.0–1.12.x
- Kubernetes v1.13.0–1.13.11
- Kubernetes v1.14.0–1.14.7
- Kubernetes v1.15.0–1.15.4
- Kubernetes v1.16.0–1.16.1

Fixed Versions:
- Kubernetes v1.13.12
- Kubernetes v1.14.8
- Kubernetes v1.15.5
- Kubernetes v1.16.2

Consider that if you are running a version prior to v1.14.0, in addition to installing the restrictive policy, turn off autoupdate for the applied ClusterRoleBinding so your changes aren't replaced on an API server restart.

On the related Github issue you can find more details that I didn't insert here for conciseness.

# Conclusion

So, that's all folks! If we followed all these rules and applied the released patches that's a good starting point for prevention and can also help on detection and remediation.

Stay tuned for the next and final episode about the E of STRIDE: Escalation of privileges!
