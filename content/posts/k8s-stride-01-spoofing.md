---
title: "STRIDE threat modeling on Kubernetes pt.1/6: Spoofing"
date: 2020-02-03T18:36:15+02:00
tags: [kubernetes, security]
categories: [kubernetes]
draft: false
---

As it comes from the power of the open source and Borg, Kubernetes is an ecosystem very flexible. Only the extensibility of the APIs as for the CRDs opens the world to a vastity of opportunities to build architectures upon it (see the SIG's Cluster API, the AWS EKS and Fargate combinations, etc.).

At the same time can be complex to manage, and everyone - or almost everyone - knows that is not enough to get applications working; as part of the administration it is vital to secure your cluster and so your application with your data to get the job done.

In security, the threat modeling is the process of identifying vulnerabilities to improve security by preventing the threats introduced by vulnerabilities.

In turn, there are different types of threats and the STRIDE model defines 6 categories of them:
- Spoofing
- Tampering
- Repudiation
- Information disclosure
- Denial of service
- Elevation of privilege

In this series of short and concise guide for threat prevention on Kubernetes, we'll go through each category of threat starting with the first one.

# Spoofing

Spoofing is pretending to be somebody or something you are not, to gain extra privileges. The process that makes sure the presented identity is real is the authentication, and in Kubernetes the authentication is based on mutual TLS.

We briefly analyze the situation from the API Server perspective and the Pod perspective.

## API Server

Starting with the API Server, the mTLS is only as secure as the Certificate Authority, so:
- The CA must be secured, so in particular:
 - the certificates issued by the CA must be used and trusted only within the cluster;
outside of Kubernetes the CA should not be trusted.
- Use two key pairs, one for internal components and one for external components, in particular:
 - use self-signed CA for internal keys;
 - third-party CA(s) for external components' certificates; in this case Kubernetes must be configured to trust it/them.

## Pod

On the pod perspective, mostly it probably does not need to access the API Server, in which case:
- since pods use Service Account to authenticate to the API server and be authorized by mounting the Service Account token as a Secret, don't mount it on Pods by default. In particular, with Kubernetes 1.6+, specifying it at the Pod level with the automountServiceAccountToken spec:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: my-pod
spec:
  serviceAccountName: build-robot
  automountServiceAccountToken: false
```

You can configure it also at the Service Account level; keep in mind that the Pod Spec takes precedence over the Service Account if both specify a automountServiceAccountToken value.

This is the end of the first pill of this series. Stay tuned for the next part.

Happy hacking!
