---
title: "STRIDE threat modeling on Kubernetes pt.3/6: Repudiation"
date: 2020-02-23T18:36:15+02:00
tags: [kubernetes, security]
categories: [kubernetes]
draft: false
---

Hi all, this is the third part of this little series about STRIDE threat modeling on Kubernetes. Previously we talked about Tampering; today we talk about **Repudiation**.

Repudiation is the ability to cast doubt on something that happened. What typically happens is that the attacker aims to deny the authorship of his actions.

Generally the opposite and thus the desired goal is prooving:
- What
- When
- Where
- Why
- Who
- How

on certain actions. Non-repudiation refers to a situation where a statement's author cannot successfully dispute its authorship and involves associating actions or changes with a unique individual.

So, we can mitigate the risks by enabling auditing on the Kubernetes components and gain visibility on actions performed by individual users, administrators or components of the system.

Let's split out the components into two categories:
- Kubernetes components
- Underline components

# Kubernetes components

## API Server

As the focal point to the API and the front end of the control plane, kube-apiserver performs auditing on the requests and for each of them, it generates an event.

Each event is then pre-processed according to a policy and then written to a backend.

The policy determines what's recorded and the backend persists the records, which can be log files or webhooks.

Each request can be recorded with an associated stage, which are:
- `RequestReceived` - The stage for events generated as soon as the audit handler receives the request, and before it is delegated down the handler chain.
- `ResponseStarted` - Once the response headers are sent, but before the response body is sent. This stage is only generated for long-running requests (e.g. watch).
- `ResponseComplete` - The response body has been completed and no more bytes will be sent.
Panic - Events generated when a panic occurred.

### Audit Policy
When an event is processed, it's compared against the list of rules of the Audit Policy in order. The first matching rule sets the audit level of the event.

In order to enable a policy, you can pass the policy file to the kube-apiserver command using the - `audit-policy-file` flag.

Is important to note that configuring a correct policy is crucial, so when configuring your own audit policy is recommended to refer to the GCE policy:

```yaml
apiVersion: audit.k8s.io/v1
kind: Policy
rules:
  # The following requests were manually identified as high-volume and low-risk,
  # so drop them.
  - level: None
    users: ["system:kube-proxy"]
    verbs: ["watch"]
    resources:
      - group: "" # core
        resources: ["endpoints", "services", "services/status"]
  - level: None
    # Ingress controller reads 'configmaps/ingress-uid' through the unsecured port.
    # TODO(#46983): Change this to the ingress controller service account.
    users: ["system:unsecured"]
    namespaces: ["kube-system"]
    verbs: ["get"]
    resources:
      - group: "" # core
        resources: ["configmaps"]
  - level: None
    users: ["kubelet"] # legacy kubelet identity
    verbs: ["get"]
    resources:
      - group: "" # core
        resources: ["nodes", "nodes/status"]
  - level: None
    userGroups: ["system:nodes"]
    verbs: ["get"]
    resources:
      - group: "" # core
        resources: ["nodes", "nodes/status"]
  - level: None
    users:
      - system:kube-controller-manager
      - system:kube-scheduler
      - system:serviceaccount:kube-system:endpoint-controller
    verbs: ["get", "update"]
    namespaces: ["kube-system"]
    resources:
      - group: "" # core
        resources: ["endpoints"]
  - level: None
    users: ["system:apiserver"]
    verbs: ["get"]
    resources:
      - group: "" # core
        resources: ["namespaces", "namespaces/status", "namespaces/finalize"]
  - level: None
    users: ["cluster-autoscaler"]
    verbs: ["get", "update"]
    namespaces: ["kube-system"]
    resources:
      - group: "" # core
        resources: ["configmaps", "endpoints"]
  # Don't log HPA fetching metrics.
  - level: None
    users:
      - system:kube-controller-manager
    verbs: ["get", "list"]
    resources:
      - group: "metrics.k8s.io"
  # Don't log these read-only URLs.
  - level: None
    nonResourceURLs:
      - /healthz*
      - /version
      - /swagger*
  # Don't log events requests.
  - level: None
    resources:
      - group: "" # core
        resources: ["events"]
  # node and pod status calls from nodes are high-volume and can be large, don't log responses for expected updates from nodes
  - level: Request
    users: ["kubelet", "system:node-problem-detector", "system:serviceaccount:kube-system:node-problem-detector"]
    verbs: ["update","patch"]
    resources:
      - group: "" # core
        resources: ["nodes/status", "pods/status"]
    omitStages:
      - "RequestReceived"
  - level: Request
    userGroups: ["system:nodes"]
    verbs: ["update","patch"]
    resources:
      - group: "" # core
        resources: ["nodes/status", "pods/status"]
    omitStages:
      - "RequestReceived"
  # deletecollection calls can be large, don't log responses for expected namespace deletions
  - level: Request
    users: ["system:serviceaccount:kube-system:namespace-controller"]
    verbs: ["deletecollection"]
    omitStages:
      - "RequestReceived"
  # Secrets, ConfigMaps, and TokenReviews can contain sensitive & binary data,
  # so only log at the Metadata level.
  - level: Metadata
    resources:
      - group: "" # core
        resources: ["secrets", "configmaps"]
      - group: authentication.k8s.io
        resources: ["tokenreviews"]
    omitStages:
      - "RequestReceived"
  # Get repsonses can be large; skip them.
  - level: Request
    verbs: ["get", "list", "watch"]
    resources: ${known_apis}
    omitStages:
      - "RequestReceived"
  # Default level for known APIs
  - level: RequestResponse
    resources: ${known_apis}
    omitStages:
      - "RequestReceived"
  # Default level for all other requests.
  - level: Metadata
    omitStages:
      - "RequestReceived"
```

Note also that the Audit Policy stands in the [audit.k8s.io](https://github.com/kubernetes/kubernetes/blob/master/staging/src/k8s.io/apiserver/pkg/apis/audit/v1/types.go) API group and the current version is v1.

### Audit Backend

Audit backends persist audit events to an external storage. Kube-apiserver out of the box provides three backends:
- [Log backend](https://kubernetes.io/docs/tasks/debug-application-cluster/audit/#log-backend), which writes audit events to a file in JSON format;
- [Webhook backend](https://kubernetes.io/docs/tasks/debug-application-cluster/audit/#webhook-backend), which sends audit events to a remote API, which is assumed to be the same API as kube-apiserver exposes;
- [Dynamic backend](https://kubernetes.io/docs/tasks/debug-application-cluster/audit/#dynamic-backend), which configures webhook backends through an AuditSink API object.

Both logging and webhook backend support [batching](https://kubernetes.io/docs/tasks/debug-application-cluster/audit/#batching) (enabled by default in webhook and disabled in log), for example to buffer events and asynchronously process them (In this case take [tuning](https://kubernetes.io/docs/tasks/debug-application-cluster/audit/#parameter-tuning) into account); they support also [truncation](https://kubernetes.io/docs/tasks/debug-application-cluster/audit/#truncate).

## Other Kubernetes components

Generally, the `kubelet` and container runtime write logs to journald, on machines with systemd. If systemd is not present, they write to .log files in the /var/log directory.
System components inside containers like the kube-scheduler and the kube-proxy always write to the `/var/log` directory, bypassing the default logging mechanism.

# Underline components
Once covered the high level of the stack is important to audit also the underline components, from the container logs to the syscalls.

## Container logs

Generally speaking, in order to decouple at scale the logging system from the application a standard interface to log streams should be used, and what's more standard of the standard streams?

I recommended writing container logs to stdout and stderr also because is handled and redirected somewhere by the container engine. For example, the Docker container engine redirects those two streams to a logging driver, which is configured in Kubernetes to write to a file in json form.

## Syscalls

Instead, speaking of system calls [Falco](https://falco.org) can detect and alert on any behavior that involves making Linux system calls. For example, you can easily detect when:

- A shell is run inside a container
- A server process spawns a child process of an unexpected type
- A sensitive file, like /etc/shadow, is unexpectedly read
- A non-device file is written to /dev
- A standard system binary (like ls) makes an outbound network connection

Falco is deployed as a long-running daemon and is configured via a general [configuration file](https://falco.org/docs/configuration/) and a [rules file](https://github.com/falcosecurity/falco/blob/master/rules/falco_rules.yaml) that is meant to be tailored to needs. [Here](https://falco.org/docs/examples/) you can see example rules that can detect anomalous events.

When Falco detects suspicious behavior, it sends alerts via one or more channels:
- Writing to standard error
- Writing to a file
- Writing to syslog
- Pipe to a spawned program. A common use of this output type would be to send an email for every Falco notification.

One difference between Falco and other tools is that Falco runs in userspace, using a kernel module and eBPF probes to obtain system calls and bring them to userspace, while the other tools perform system call filtering/monitoring at the kernel level; thanks to that it can have a much richer set of information powering its policies.

Beyond system calls Falco's event sources can be also Kubernetes Events that are filtered through these rules. For this purpose, it exposes a webhook endpoint that can be used as a Kubernetes Audit webhook backend.

In order to install and configure it please refer to the official docs.

# Logs management
As for all logs, it is important to collect them and possibly ship them to a centralized and secured log store, available for further process.

Different shipping and collecting tools can be leveraged, such as [fluentd](https://www.fluentd.org/) and [logstash](https://www.elastic.co/logstash). We'll not deepen about it here for conciseness.

# Conclusion

This post is not intended to provide the truth, instead to provide insights from my point of view. I purposely did not cover the auditing implementations of the cloud providers, to shift the focus on the fundamentals.

I hope it was interesting for you, if you liked it please let me know, if you don't agree please let me know, I appreciate sharing opinions and I always aim to learn something new and from different points of view!

For this post that's all, happy hacking!
