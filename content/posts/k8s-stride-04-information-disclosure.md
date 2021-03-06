---
title: "STRIDE threat modeling on Kubernetes pt.4/6: Information disclosure"
date: 2020-03-23T18:36:15+02:00
tags: [kubernetes, security]
categories: [kubernetes]
draft: false
---

This is the fourth part of a series about STRIDE threat modeling in Kubernetes. In the previous part we talked about repudiation, instead today we'll going to address **information disclosure**.

Information disclosure happens with data leaks or data breaches, whenever a system that is designed to be closed to an eavesdropper unintentionally reveals some information to unauthorized parties.

To prevent this we should protect data in transit and at rest by guaranteeing confidentiality, which can be guaranteed with encryption.

Most of the data in Kubernetes is part of his state, the sensitive part of which is represented by Secret API objects, stored in ectd. So, first of all, to prevent information disclosure we should encrypt data, especially secret, at rest and in transit.

Furthermore, we should consider also data that can be sensitive or at least be used to gain extra privileges in the cluster or in the cloud provider, such as all sensitive data generated by our workload that won't be stored in Secrets or, for example, cloud metadata from the cloud provider's API.

But let's go deeper and start from data at rest.

# Data at rest

As we said, to avoid unwanted parts access sensitive data, we can restrict access to it. At the same time, to avoid that even if that data is unintentionally accessed it can be read, we can encrypt it.

## Restrict access

### etcd

Only the API server and other etcd nodes should be able to access etcd since write access is equivalent to gaining root on the entire cluster, and read access can be used to gain extra privileges.

You can enforce restrictions on it with ACL at firewall-level and with strong authentication with PKI and X.509 certificates, which are supported by etcd.

Two are the authentication to consider:
- between etcd peers
- between the API server and etcd.

To secure communications between etcd peers you can use these etcd flags:
- –peer-key-file=<peer.key>
- –peer-cert-file=<peer.cert>
- –peer-client-cert-auth
- –peer-trusted-ca-file=<etcd-ca.cert>

To secure communication between the API server and etcd use these ones:
- –cert-file=<server.crt>
- –key-file=<server.key>
- –client-cert-auth
- –trusted-ca-file=<etcd-ca.crt>

and at the same time configure the API server with these flags:
- –etcd-certfile=<client.crt>
- –etcd-keyfile=<client.key>

Note: in this case in order to allow API server to communicate with etcd the certificate client.crt should be trusted by the CA with certificate etcd-ca.crt.
[Here](https://github.com/etcd-io/etcd/tree/main/hack/tls-setup) you can find scripts to setup certs and key pairs for these individuals communications.

Consider all of that for learning purposes because if you - or your provider - set up the cluster with kubeadm, it manages all of that by built-in and you likely won't need to setup PKI for etcd and API server by yourself, except only for advanced cases.

Anyway, we'll talk about PKI management with kubeadm later.

### Secret API

When deploying applications that interact with the Secret API, you should limit access using RBAC policies.

Consider that Secrets can also be used to gain extra privileges, as for service account tokens. For example, components that create pods inside system namespaces like kube-system can be unexpectedly powerful because those pods can gain access to service account secrets or run with elevated permissions if those service accounts are granted access to permissive PSPs.

For this reason always review permissions that components need: generally watch and list requests for secrets within a namespace should be avoided since listing Secrets allows the clients to inspect the values of all Secrets that are in that namespace. The permission to watch and list all Secrets in a cluster should be reserved only to trusted system components.
To let applications access the Secret objects it should be allowed only get requests on the needed Secrets, in order to apply the least privilege principle and denying by default.

Furthermore, consider that if a user can create a Pod that uses a Secret, he could expose the Secret even if the API server policy does not allow that user to read the Secret.

Another method to access the Secret API objects can be by impersonating the kubelet because it can be read any Secret from the API server.
You can prevent this by enforcing authentication and authorization restrictions on the kubelet binary, on the RBAC permissions, but in this case, you should migrate to manage the authorization on kubelets with Node Authorization and enabling the Node restriction admission controller.

In addition, review the RBAC permissions of the objects that access the kubelet.

### Secret Volumes

A Secret is sent to a node only if a Pod on that node requires it and the kubelet stores the Secret into a tmpfs so that the Secret is not written to disk storage. Once the Pod that depends on the Secret is deleted, the kubelet will delete its local copy of the secret data as well.

Furthermore, only the Secrets that a pod requests are potentially visible within its containers. Therefore, one Pod does not have access to the Secrets of another Pod. And each container in a Pod has to request the Secret volume in its volumeMounts for it to be visible within the container.

So, the prevention can be made by design, by separating the responsibilities and by not exposing services that have access to Secrets as much as possible.

You can enforce Secret access control from Pods with external secret managers like [Vault](https://www.vaultproject.io/) that from December 2019 supports Secret injection with [vault-k8s](https://learn.hashicorp.com/vault/identity-access-management/vault-agent-k8s), which is a Kubernetes mutating admission control webhook that alters pod spec to include Vault Agent containers that render Vault secrets to a shared memory volume, so that containers within the pod only need to read filesystem data without being aware of Vault.

[Here](https://www.hashicorp.com/blog/injecting-vault-secrets-into-kubernetes-pods-via-a-sidecar) you can read their blog post about it.

### Cloud metadata API

In addition to data restrictively stored in Kubernetes, cloud providers often expose metadata services locally to instances. By default, these APIs are accessible by pods running on an instance and can contain cloud credentials for that node, or provisioning data such as kubelet credentials. These credentials can be used to escalate within the cluster or to other cloud services under the same account.

When running Kubernetes on a cloud platform [limit permissions](https://kubernetes.io/docs/tasks/administer-cluster/securing-a-cluster/#restricting-cloud-metadata-api-access) are given to instance identities (for example fine-tuning IAM instance roles in AWS), use Kubernetes [Network Policies](https://kubernetes.io/docs/concepts/services-networking/network-policies/) to restrict pod access to the metadata API, and avoid using provisioning data to deliver secrets.

## Encrypt

### etcd

You can encrypt data stored in etcd by enable Kubernetes [encryption at rest](https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/) feature, that is available in beta version from version 1.13, so that the Secrets are not stored in plaintext into [etcd](https://kubernetes.io/docs/tasks/administer-cluster/configure-upgrade-etcd/), and even if an attacker can gain access to it, he can't read it; so let's see briefly how it works.

The API server binary accepts an argument - encryption-provider-config to pass an encryption configuration that controls how data is encrypted in etcd. The configuration is an API object that is part of the `apiserver.config.k8s.io` API group, as you can see in the example below:

```yaml
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources:
    - secrets
    providers:
    - aescbc:
        keys:
        - name: key1
          secret: <BASE 64 ENCODED SECRET>
    - identity: {}
```

As you can see each resources array item is a separate complete configuration; the resources.resources field is an array of resource names (i.e. secrets) that should be encrypted.

The [providers](https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/#providers) array is an ordered list of the possible encryption providers which currently are:
- identity
- aescbc
- secretbox
- aesgcm
- kms

**Important**: note that as the first provider specified in the list is used to encrypt resources, and since the identity provider is used by default which provides no encryption, if you place it as the first item you disable encryption.

Furthermore, since the config file can contain keys that can decrypt content in etcd, you should restrict permissions on your master nodes so only the user who runs the API server can read it.

A better approach is envelope encryption where it's generated a data encryption key that encrypts the data, and then the data encryption key is encrypted with a key encryption key to protect it.
It could be encrypted also the KEK but eventually, one key must be in plaintext in order to decrypt the keys and finally the data.
The top-level key is the master key and it should be stored outside of the cluster.

Doing so, you don't have to worry about storing the encrypted data key, because it is protected by encryption; furthermore, since the data could be large, you gain in performance as you don't have to re-encrypt multiple times the same data with different keys, but you can re-encrypt only the data keys that protects the data.

The [KMS encryption provider](https://kubernetes.io/docs/tasks/administer-cluster/kms-provider/) uses envelope encryption to encrypt data in etcd and the master/key encryption key is stored and managed in a remote KMS, letting the user be able to rotate it. The KMS provider uses gRPC to communicate with a specific KMS plugin; the KMS plugin, which is implemented as a gRPC server, communicates with the remote KMS.

Note that if you are using EKS they just introduced the support for envelope encryption of Secrets with KMS a little time ago; [here](https://aws.amazon.com/it/about-aws/whats-new/2020/03/amazon-eks-adds-envelope-encryption-for-secrets-with-aws-kms/) the announcement.

Other than etcd, you can prevent from reading secret data by encrypting your backups as well as full disks; for example, if your cluster runs in AWS on EC2 instances you can enable encryption of EBS volumes, or if you use EKS for example is provided by default.

### VCS

If you configure secret data in general (Secrets objects, inputs for [Kustomize](https://kustomize.io) [secret generators](https://github.com/kubernetes-sigs/kustomize/blob/master/examples/secretGeneratorPlugin.md), chart values, etc.) through a manifest which has the secret data encoded as base64 and you choose to put under git versioning that data, it means the secret is compromised becase Base64 encoding is not an encryption method and it will be the same as plain text.

You can protect that versioned secret by encrypting it using tools like git-crypt or even better [SOPS](https://github.com/mozilla/sops), which integrates very well with most cloud provider's KMS, other than PGP.

You can reach a level of granularity where you use an AWS KMS Customer Master Key and a least-privilege AWS IAM role both dedicated only to a single file inside a repository, to encrypt and decrypt… that's amazing! If you are interested and you don't already know it, this introductive [video](https://www.youtube.com/watch?v=V2PRhxphH2w) is recommended.

Furthermore, as Helm is the de-facto standard for package management and you likely want to version chart configurations, in case these contain secret data you likely also want to protect them. Even here you can leverage SOPS by using the [helm-secrets](https://github.com/zendesk/helm-secrets) Helm plugin.
Logs

A little additional point: even if all the above measures taken place, be sure to not accidentally expose secret data read from volumes or environment by writing it to logs or shipping it to external services, for example data collectors.

# Data in transit

## Encrypt

Other than the data at rest is important to encrypt in-transit data.
TLS provides a protocol to manage encryption of the data in communications between two parties.

It defines how they agree on the cipher suite, that is a set of algorithms to secure the connection, which usually contains the algorithm used to exchange the encryption key, the encryption algorithm itself, the message authentication code (MAC) algorithm for integrity check, and optionally an authentication algorithm. TLS itself decides which are the required features of supported cipher suites (for example in TLS 1.3, many legacy algorithms have been dropped).

Authentication in TLS is an optional feature but is highly recommended, and by default using the security features of etcd you protect in-transit data with encryption via TLS and restrict the communication to only trusted peers with a Public Key Infrastructure and X.509 certificates.

In the Kubernetes world in order to protect the communications you must consider data transmitted between and to Kubernetes components and between application components.

### Between/to Kubernetes components

On most Kubernetes distributions, communication between master and worker components, is protected by TLS. Specifically the same applies between etcd nodes, and between API server and etcd as explained above.

In this way data and specifically sensitive data in transit is protected when transmitted over these channels.

If you install Kubernetes with kubeadm, the certificates that your cluster requires are automatically generated and placed under /etc/kubernetes/pki. Consider that Kubernetes requires PKI for the following operations:
- Client certificates for the kubelet + kubeconfig to authenticate to the API server
- Server certificate for the API server endpoint
- Client certificates + kubeconfig for administrators of the cluster to authenticate to the API server
- Client certificates for the API server to talk to the kubelets
- Client certificate for the API server to talk to etcd
- Client certificate + kubeconfig for the controller manager to talk to the API server
- Client certificate + kubeconfig for the scheduler to talk to the API server
- Client and server certificates for etcd to authenticate between themselves

If you run `kube-proxy` to support an extension API Server, client and server certificates for the front-proxy

In case you don't want to let kubeadm to create these certificates for example because you need to integrate your certificate infrastructure into a kubeadm-built cluster you can either create and [inject intermediate CAs](https://kubernetes.io/docs/setup/best-practices/certificates/#single-root-ca) from your root CA to let kubeadm to create the certificates or, in case you don't want to copy your CAs into the cluster you can [create all the certificates](https://kubernetes.io/docs/setup/best-practices/certificates/#all-certificates) by yourself. Anyway proceed only if you know what are you doing and consider that in most cases the default kubeadm configuration is fine.

For the control plane, the certificates are valid for one year and kubeadm renews them by default during the control plane upgrade. If this configuration does not fit your need you can disable renewal during upgrade by passing - certificate-renewal=false option to `kubeadm upgrade apply` or to `kubeadm upgrade node`.

Then, you can even manage the renewals manually via the Kubernetes [`Certificates` API](https://kubernetes.io/docs/tasks/tls/managing-tls-in-a-cluster/) by signing the certificates with the controller manager's built-in signer or by using systems like [cert-manager](https://cert-manager.io); furthermore, you can also renew certificates with your external CA and let kubeadm [create only your CSRs](https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-certs/#renew-certificates-with-external-ca).

Instead, the certificate and `kubeconfig` of the `kubelet` are automatically updated by themselves; take a look here also for automatic certificates bootstrapping of the kubelets for communications to the API server, needed for example when scaling up the worker nodes.

By the way, you likely won't need to do a lot of work to secure communications between Kubernetes components, as kubeadm manages most of the parts of the PKI; moreover, if a cloud provider hosts your cluster it probably also offers additional operational features.

### Between application components

For components that you develop and deploy, consider to encrypt the communications with mTLS to provide mutual authentication between them, by leveraging service meshes like [Istio](https://istio.io/latest/docs/tasks/security/authentication/mtls-migration/) or [Linkerd](https://linkerd.io/2/features/automatic-mtls/), where other than encryption you guarantee that both components are trusting each other and they manage entirely the PKI for your mesh.

You could also setup and manage PKI by yourself by using certificate managers like cert-manager that works with external CAs, for example,b provided by Vault (yes, it can also be used as a root/intermediate CA). Anyway, it's not a good idea since it can be complex, especially in situations where you have microservices… you would freak out.

A service mesh framework provides also a lot of features; on the security perspective, it can covers also authorization and audit, other than authentication (and encryption), as Istio does with [secure naming](https://istio.io/latest/docs/concepts/security/#secure-naming) that maps server identities encoded in certificates with service names and checks against policies, to control if an identity is authorized to run a service.

But that is only a part of the security aspects that a service mesh covers; it can manage load balancing, access control, observability, canary releasing, etc. They can cover also the authentication from the end-user, other than in communications between services, for example by supporting OpenID Connect providers.
In addition to the encryption of the whole communication, you can and should also encrypt specific sensitive data by leveraging secrets manager like Vault; it also provides [encryption as a service](https://learn.hashicorp.com/tutorials/vault/eaas-transit) thanks to its transit secrets engine.

You can use Vault to generate and manage tokens, which in turn - as said before - can be injected runtime into your workload without being aware of the secrets manager.

Finally, if you'd deploy third-party components consider that Kubernetes expects that all API communication in the cluster is encrypted by default with TLS, and the majority of installation methods will allow the necessary certificates to be created and distributed to the cluster components.

Anyway some components and installation methods may enable local ports over HTTP, so you should check every setting to identify potentially unsecured traffic and, if supported, enable TLS encryption and if not, look for alternative components that will do.

# Conclusion

*"The power of a system comes more from the relationships among programs than from the programs themselves"* (The UNIX Programming Environment).
As the UNIX way probably shaped the Kubernetes architecture the relationships are to be carefully managed and secured as like as the data that transits in and be generated by.

Whereas this, this part covered a lot of aspects and because of that it has been hard to put practice demos; anyway I tried to provide as much references as I can to let you deepen by yourself the topics you're most interested in.

That's all folks! I hope you liked this part and to I hope to see you later in the next part about Denial of service.

Happy hacking!
