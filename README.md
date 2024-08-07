# Strimzi, Envoy Gateway, and the Gateway API

At [LittleHorse](https://littlehorse.dev), we use the [Gateway API](https://gateway-api.sigs.k8s.io) to allow external traffic into our kubernetes clusters. We will soon need to allow external clients to access our [Kafka](https://kafka.apache.org) clusters (managed by Strimzi, of course!) from outside ouf our Kubernetes clusters. We have so far been pleased with the performance and simplicity of [Envoy Gateway](https://gateway.envoyproxy.io/) as a Gateway Controller, which motivated this investigation into using Envoy Gateway to access our Kafka clusters.

## Background

The [Gateway API](https://gateway-api.sigs.k8s.io/) in Kubernetes aims to replace the `Ingress` resource as the de facto standard for allowing external traffic to reach workloads running on Kubernetes. It addresses many shortcomings of the `Ingress` resource, including poor support for non-HTTP 1.0 traffic.

![Strimzi and Envoy Gateway](./strimzi-envoy-gateway.png)

### Accessing Kafka

Previously, Jakub Scholz blogged about how Strimzi allows you to access Kafka from outside the Kubernetes cluster using [`NodePort` services](https://strimzi.io/2019/04/23/accessing-kafka-part-2.html), [OpenShift `Route`s](https://strimzi.io/2019/04/30/accessing-kafka-part-3.html), [`LoadBalancer` Services](https://strimzi.io/2019/05/13/accessing-kafka-part-4.html), and [`Ingress` resources](https://strimzi.io/blog/2019/05/23/accessing-kafka-part-5/).

As a Strimzi maintainer [blogged in the past](https://strimzi.io/blog/2019/04/17/accessing-kafka-part-1/), accessing Kafka is difficult for two reasons:

1. Kafka Clients need to be able to access specific brokers individually, so simply scattering the requests across the Kafka Cluster using a load balancer would yield incorrect results.
2. The Kafka protocol is not based on HTTP, which means that you need a few clever hacks to get it to work with plain `Ingress`.

### The Gateway API

The Gateway API is a much more flexible and extensible take on north-south traffic than `Ingress`. The entirety of the Gateway API is beyond the scope of this post, but there are two resources in particular that will be of interest to us:

1. `TCPRoute`s, which proxy unencrypted TCP traffic.
2. `TLSRoute`s, which control encrypted TCP traffic.

The `HTTPRoute` and `GRPCRoute` resources will not work with Kafka because Kafka does not speak an HTTP-based protocol.

_NOTE: The `HTTPRoute` resource has reached GA in the Gateway API; however, the `TLSRoute` is still in beta. Some advise not using it, but it should be fine as long as you check release notes and test before upgrading!_

## Putting It Into Practice

The rest of this blog post will walk through how to use `TLSRoute`s to access a Strimzi-managed Kafka cluster from outside of your Kubernetes cluster. We will use a [KIND](https://kind.sigs.k8s.io/) cluster, which allows us to run a Kubernetes cluster in docker containers on our local machine, and we will use Envoy Gateway as our implementation of the Gateway API.

### KIND Cluster Setup

First, let's create the KIND cluster using the following `kind-config.yaml` file:

```
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- kubeadmConfigPatches:
  - |
    kind: InitConfiguration
    nodeRegistration:
      kubeletExtraArgs:
        node-labels: "ingress-ready=true"
  extraPortMappings:
  - containerPort: 30992
    hostPort: 9092
    protocol: TCP
```

If you inspect the `kind-config.yaml` file, you will notice the port mapping of `hostPort: 9092` being mapped to `containerPort: 30992`. That means that the port 9092 on your own laptop will be forwarded by docker to port 30992 on the Kubernetes Node (which, in KIND, is just a docker container running on your laptop). We will use this fact when installing Envoy Gateway.

```
kind create cluster --name strimzi-gw-api --config kind-config.yaml
```

Next, let's set up Envoy Gateway. First, we will use `helm` to install it.

```
helm upgrade --install envoygateway oci://docker.io/envoyproxy/gateway-helm \
    --version v1.0.1 \
    --namespace envoy-gateway-system \
    --create-namespace
```

Once the installation process is complete, we need to deploy a `Gateway` with a specific `GatewayClass` that will listen on the correct `NodePort`s. We'll refer to this `Gateway` later when we create `TLSRoute`s to access our Kafka cluster. Let's apply the following file:

```
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: my-gateway-class
  namespace: envoy-gateway-system
spec:
  controllerName: gateway.envoyproxy.io/gatewayclass-controller
  parametersRef:
    group: gateway.envoyproxy.io
    kind: EnvoyProxy
    name: my-proxy-config
    namespace: envoy-gateway-system
---
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: EnvoyProxy
metadata:
  name: my-proxy-config
  namespace: envoy-gateway-system
spec:
  provider:
    type: Kubernetes
    kubernetes:
      envoyDeployment:
        replicas: 1
      envoyService:
        type: NodePort
        patch:
          value:
            spec:
              ports:
              # Port 9092 on your laptop gets forwarded to NodePort 30992 on the KIND cluster.
              - name: kafka-port
                nodePort: 30992
                port: 9092
                protocol: TCP
                targetPort: 9092
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: my-gateway
  namespace: default
spec:
  gatewayClassName: my-gateway-class
  listeners:
  - name: kafka-listener
    protocol: TLS
    port: 9092
    tls:
      mode: Passthrough
```

```
kubectl apply -f envoy-gateway-base.yaml
```

Once that is done, you should see some pods in the `envoy-gateway-system` namespace, like the following:

```
-> kubectl get pods --namespace envoy-gateway-system
NAME                                                 READY   STATUS    RESTARTS   AGE
envoy-default-my-gateway-1c7c06f0-5446c7ff7b-vpd6m   1/2     Running   0          22s
envoy-gateway-8595cc9fbc-2bjn5                       1/1     Running   0          96s
```

The second pod is the Envoy Gateway controller, which reconciles all Gateway API-related resources. The first `Pod` was created by the controller to route all traffic for the `my-gateway` `Gateway` which we created in the `default` namespace.

Next, the most exciting part about the setup process is installing Strimzi. You can do it as follows:

```
helm upgrade --install strimzi oci://quay.io/strimzi-helm/strimzi-kafka-operator \
    --version 0.42.0 \
    --namespace default
```

Since the `TLSRoute` resource uses _passthrough TLS_, in which encryption is terminated at the Kafka broker pods, we'll need a TLS certificate to mount on the Kafka brokers. While we could use `openssl`, in this example we'll use another operator, [Cert Manager](https://cert-manager.io), to create TLS certificates for us using the `Certificate` resource.

You can install Cert Manager as follows:

```
helm upgrade --install cert-manager jetstack/cert-manager \
    --namespace default \
    --version v1.15.1 \
    --set installCRDs=true
```

Next, create a self-signed `Issuer` and a `Certificate`:

```
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: my-certificate
  namespace: default
spec:
  secretName: my-certificate
  subject:
    organizations:
    - my-org
  privateKey:
    algorithm: RSA
    encoding: PKCS8
    size: 2048
  usages:
  - server auth
  - client auth
  dnsNames:
  - '*.strimzi.gateway.api.test'
  issuerRef:
    name: my-issuer
    kind: ClusterIssuer
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: my-issuer
  namespace: default
spec:
  selfSigned: {}
```

```
kubectl apply -f certificate.yaml
```

You should be able to see a `Secret` named `my-certificate` in the `default` namespace.

The last piece of setup is to configure your `/etc/hosts` file so that you can access Kafka from outside of the cluster. This is one of two hacks that we will use to get this example to work on your local KIND box—in real life, you would probably use real DNS records to point to your Kubernetes Cluster. In this case, we want to make `*.strimzi.gateway.api.test` point to `localhost` so that it ends up hitting the KIND node (which is just a docker container running on `localhost`).

Add the following to `/etc/hosts`:

```
# For Strimzi Gateway API
127.0.0.1 bootstrap.strimzi.gateway.api.test
127.0.0.1 broker-10.strimzi.gateway.api.test
127.0.0.1 broker-11.strimzi.gateway.api.test
127.0.0.1 broker-12.strimzi.gateway.api.test
```

We will:
* Make it so that any traffic sent to those endpoints (on port `9092`) ends up at the Envoy Gateway pod(s).
* Configure our Kafka cluser to advertise the above endpoints.
* Create `TLSRoute`s that route traffic from the Envoy Gateway pods to the appropriate Kafka brokers using the Server Name Indication protocol.

### Deploying the `Kafka` Cluster

Let's create a Kafka cluster. Our cluster will have 1 Controller and 3 Brokers. This means we're going to need a single `Kafka` resource and two `KafkaNodePool`s.

Our `Kafka` cluster will have one listener on it, on port `9092`:

```
# ...
spec:
  kafka:
    listeners:
    - port: 9092
# ...
```

We'll need to use the `cluster-ip` listener type so that Strimzi creates a `Service` of `type: ClusterIP` for each broker. This enables us to use `TLSRoute`s to send traffic to the proper broker on the backend.

```
# ...
    - port: 9092
      type: cluster-ip
# ...
```

Additionally, since we're exposing our Kafka cluster to the internet, we'll use `scram-sha-512` authentication to secure the listener:

```
# ...
      authentication:
        type: scram-sha-512
# ...
```

Rather than have Strimzi create the certificates for us, we want to use the `my-certificate` secret created by Cert Manager. Most importantly, we need to configure the advertised listeners on the brokers so that they advertise the endpoints that we set above.

_NOTE: we will configure the broker `KafkaNodePool` to start with node id `10` so that we guarantee that we expose only the brokers and not the controllers._

```
      configuration:
        brokerCertChainAndKey:
          certificate: tls.crt
          key: tls.key
          secretName: my-certificate
        brokers:
        - advertisedHost: broker-10.strimzi.gateway.api.test
          advertisedPort: 9092
          broker: 10
        - advertisedHost: broker-11.strimzi.gateway.api.test
          advertisedPort: 9092
          broker: 11
        - advertisedHost: broker-12.strimzi.gateway.api.test
          advertisedPort: 9092
          broker: 12
        createBootstrapService: true

```

Putting it together, the `Kafka` resource looks like the following:

```
apiVersion: kafka.strimzi.io/v1beta2
kind: Kafka
metadata:
  name: gateway-api-test
  namespace: default
  annotations:
    strimzi.io/kraft: enabled
    strimzi.io/node-pools: enabled
spec:
  entityOperator:
    # We'll create a kafka topic and user so we need these operators.
    topicOperator: {}
    userOperator: {}
  kafka:
    authorization:
      type: simple
    listeners:
    - authentication:
        type: scram-sha-512
      configuration:
        brokerCertChainAndKey:
          certificate: tls.crt
          key: tls.key
          secretName: my-certificate
        brokers:
        - advertisedHost: broker-10.strimzi.gateway.api.test
          advertisedPort: 9092
          broker: 10
        - advertisedHost: broker-11.strimzi.gateway.api.test
          advertisedPort: 9092
          broker: 11
        - advertisedHost: broker-12.strimzi.gateway.api.test
          advertisedPort: 9092
          broker: 12
        createBootstrapService: true
      name: obiwan
      port: 9092
      tls: true
      type: cluster-ip
    version: 3.7.1
```

```
kubectl apply -f kafka.yaml
```

Next, we need to create the `KafkaNodePool`s for the controllers and the brokers. We will ensure that the controller node id's start at `0` and the brokers start at `10`. Our cluster will only have one controller, but in production it's recommended to use 3. Note that before [KIP-853](https://cwiki.apache.org/confluence/display/KAFKA/KIP-853%3A+KRaft+Controller+Membership+Changes) is completed in Apache Kafka and supported in Strimzi, it is not possible to change the number of controllers in your cluster once it's deployed. Hopefully, that will be addressed in the upcoming Kafka `3.9.0` release and soon after in Strimzi.

```
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaNodePool
metadata:
  annotations:
    strimzi.io/next-node-ids: '[10-100]'
  labels:
    strimzi.io/cluster: gateway-api-test
  name: broker
  namespace: default
spec:
  replicas: 3
  roles:
  - broker
  storage:
    class: standard
    size: 10G
    type: persistent-claim
---
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaNodePool
metadata:
  annotations:
    strimzi.io/next-node-ids: '[0-9]'
  labels:
    strimzi.io/cluster: gateway-api-test
  name: controller
  namespace: default
spec:
  replicas: 1
  roles:
  - controller
  storage:
    class: standard
    size: 10G
    type: persistent-claim
```

```
kubectl apply -f kafka-node-pools.yaml
```

At this point, you should see the Kafka pods up and running.

```
NAME                                                READY   STATUS    RESTARTS   AGE
cert-manager-84489bc478-7cxds                       1/1     Running   0          7m22s
cert-manager-cainjector-7477d56b47-ct8dv            1/1     Running   0          7m22s
cert-manager-webhook-6d5cb854fc-2rx9p               1/1     Running   0          7m22s
gateway-api-test-broker-10                          1/1     Running   0          82s
gateway-api-test-broker-11                          1/1     Running   0          82s
gateway-api-test-broker-12                          1/1     Running   0          82s
gateway-api-test-controller-0                       1/1     Running   0          82s
gateway-api-test-entity-operator-6657fbc775-w4b65   2/2     Running   0          44s
strimzi-cluster-operator-6948497896-s7q46           1/1     Running   0          2m23s
```

### Creating `TLSRoute`s

Next, we will need to create four `TLSRoute`'s:

* A `bootstrap` one that points to the bootstrap service.
* A `TLSRoute` for each broker that is deployed.

It will be as follows:

```
apiVersion: gateway.networking.k8s.io/v1alpha2
kind: TLSRoute
metadata:
  name: gateway-api-test-broker-10
  namespace: default
spec:
  hostnames:
  - broker-10.strimzi.gateway.api.test
  parentRefs:
  - group: gateway.networking.k8s.io
    kind: Gateway
    name: my-gateway
    namespace: default
    sectionName: kafka-listener
  rules:
  - backendRefs:
    - group: ""
      kind: Service
      name: gateway-api-test-broker-obiwan-10
      port: 9092
---
apiVersion: gateway.networking.k8s.io/v1alpha2
kind: TLSRoute
metadata:
  name: gateway-api-test-broker-11
  namespace: default
spec:
  hostnames:
  - broker-11.strimzi.gateway.api.test
  parentRefs:
  - group: gateway.networking.k8s.io
    kind: Gateway
    name: my-gateway
    namespace: default
    sectionName: kafka-listener
  rules:
  - backendRefs:
    - group: ""
      kind: Service
      name: gateway-api-test-broker-obiwan-11
      port: 9092
---
apiVersion: gateway.networking.k8s.io/v1alpha2
kind: TLSRoute
metadata:
  name: gateway-api-test-broker-12
  namespace: default
spec:
  hostnames:
  - broker-12.strimzi.gateway.api.test
  parentRefs:
  - group: gateway.networking.k8s.io
    kind: Gateway
    name: my-gateway
    namespace: default
    sectionName: kafka-listener
  rules:
  - backendRefs:
    - group: ""
      kind: Service
      name: gateway-api-test-broker-obiwan-12
      port: 9092
---
apiVersion: gateway.networking.k8s.io/v1alpha2
kind: TLSRoute
metadata:
  name: gateway-api-test-bootstrap
  namespace: default
spec:
  hostnames:
  - bootstrap.strimzi.gateway.api.test
  parentRefs:
  - group: gateway.networking.k8s.io
    kind: Gateway
    name: my-gateway
    namespace: default
    sectionName: kafka-listener
  rules:
  - backendRefs:
    - group: ""
      kind: Service
      name: gateway-api-test-kafka-obiwan-bootstrap
      port: 9092
```

```
kubectl apply -f tls-routes.yaml
```

### Creating a Kafka Client Config

In order to access Kafka, we will create a `KafkaUser` that will create credentials as a Kubernetes `Secret` for us to access the secured Kafka cluster. We'll also create a `KafkaTopic` to play with in the next section.

First, create a `KafkaUser` and `KafkaTopic`:

```
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaUser
metadata:
  name: obiwan
  namespace: default
  labels:
    strimzi.io/cluster: gateway-api-test
spec:
  authentication:
    type: scram-sha-512
  authorization:
    type: simple
    acls:
    - resource:
        type: topic
        name: "*"
        patternType: literal
      operations:
        - 'All'
      host: "*"
    - resource:
        type: group
        name: "*"
        patternType: literal
      operations:
        - 'All'
      host: "*"
    - resource:
        type: cluster
      operations:
        - 'All'
    - resource:
        type: transactionalId
        name: "*"
        patternType: literal
      operations:
        - 'All'
---
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaTopic
metadata:
  name: my-topic
  namespace: default
  labels:
    strimzi.io/cluster: gateway-api-test
spec:
  partitions: 12
  replicas: 3
```

```
kubectl apply -f user-and-topic.yaml
```

```
-> kubectl get kafkauser
NAME     CLUSTER            AUTHENTICATION   AUTHORIZATION   READY
obiwan   gateway-api-test   scram-sha-512    simple          True

-> kubectl get kafkatopic
NAME       CLUSTER            PARTITIONS   REPLICATION FACTOR   READY
my-topic   gateway-api-test   12           3                    True
```

You should now see a `Secret` named `obiwan`. If you inspect it, you'll see a `sasl.jaas.config` field which contains a base64-encoded String that can be passed for the Kafka `sasl.jaas.config` configuration property.

To access Kafka, we need to create a client configuration property. We will need to do the following:

1. Download the `sasl.jaas.config` from the `Secret` created for the `KafkaUser`.
2. Download the CA Public Cert created by Cert Manager.
3. Convert the CA Cert from the previous step into the JKS format so that we can use it in our Kafka config.

The following script does all of that and writes a Kafka config file to `/tmp/kafka-client-config.properties`.

```
#!/bin/bash

kubectl get secret my-certificate -o json | jq '.data."ca.crt"' | tr -d '"' | base64 --decode > /tmp/ca.crt
keytool -importcert -alias ca -file /tmp/ca.crt -keystore /tmp/strimzi-kafka-truststore.jks -storepass kenobi

JAAS_CONFIG=$(kubectl get secret obiwan -o json | jq '.data."sasl.jaas.config"' | tr -d '"' | base64 --decode)

cat <<EOF > /tmp/kafka-client-config.properties
bootstrap.servers=bootstrap.strimzi.gateway.api.test:9092
sasl.jaas.config=$JAAS_CONFIG
security.protocol=SASL_SSL
sasl.mechanism=SCRAM-SHA-512
ssl.truststore.location=/tmp/strimzi-kafka-truststore.jks
ssl.truststore.password=kenobi
EOF
```

When running the script make sure to type "yes" to add the certificate to the JKS keystore.
```
./create-kafka-config.sh
cat /tmp/kafka-client-config.properties
```

### Accessing Kafka

The last thing we need to do is use our Kafka cluster! We'll use the Strimzi docker images and the `kafka-console-{producer,consumer}.sh` scripts.

In one terminal, start a consumer:

```
docker run -it --rm --network host \
    -v /tmp/:/tmp/ quay.io/strimzi/kafka:0.42.0-kafka-3.7.1 \
    bin/kafka-console-consumer.sh \
    --bootstrap-server bootstrap.strimzi.gateway.api.test:9092 \
    --topic my-topic \
    --from-beginning \
    --consumer.config /tmp/kafka-client-config.properties
```

And in another, start a producer:

```
docker run -it --rm --network host \
    -v /tmp/:/tmp/ quay.io/strimzi/kafka:0.42.0-kafka-3.7.1 \
    bin/kafka-console-producer.sh \
    --bootstrap-server bootstrap.strimzi.gateway.api.test:9092 \
    --topic my-topic \
    --producer.config /tmp/kafka-client-config.properties
```

## Conclusion

Strimzi has native support for `Ingress`, OpenShift `Route`s, and `LoadBalancer` and `NodePort` services. This support covers the vast majority of use-cases; however, Strimzi is still flexible enough for you to implement your own custom listeners that use different mechanisms for allowing north-south traffic into your Kafka cluster.

In this example, we have shown you how to securely leverage Envoy Gateway's implementation of the new Gateway API, which is poised to become the de facto standard for Kubernetes networking over the next few years. For now, extending Strimzi to use the Gateway API is somewhat manual, but who knows...it may become natively-supported within Strimzi some day!
