# Accessing Kafka with the Gateway API

The [Gateway API](https://gateway-api.sigs.k8s.io/) in Kubernetes aims to replace the `Ingress` resource as the de facto standard for allowing external traffic to reach workloads running on Kubernetes. It addresses many shortcomings of the `Ingress` resource, including poor support for non-HTTP 1.0 traffic.

## Accessing Kafka

Previously, Jakub Scholz blogged about how Strimzi allows you to access Kafka from outside the Kubernetes cluster using [`NodePort` services](https://strimzi.io/2019/04/23/accessing-kafka-part-2.html), [OpenShift `Route`s](https://strimzi.io/2019/04/30/accessing-kafka-part-3.html), [`LoadBalancer` Services](https://strimzi.io/2019/05/13/accessing-kafka-part-4.html), and [`Ingress` resources](https://strimzi.io/blog/2019/05/23/accessing-kafka-part-5/).

As a Strimzi maintainer [blogged in the past](https://strimzi.io/blog/2019/04/17/accessing-kafka-part-1/), accessing Kafka is difficult for two reasons:

1. Kafka Clients need to be able to access specific brokers individually, so simply scattering the requests across the Kafka Cluster using a load balancer would yield incorrect results.
2. The Kafka protocol is not based on HTTP, which means that you need a few clever hacks to get it to work with plain `Ingress`.

## The Gateway API

The Gateway API is a much more flexible and extensible take on north-south traffic than `Ingress`. The entirety of the Gateway API is beyond the scope of this post, but there are two resources in particular that will be of interest to us:

1. `TCPRoute`s, which proxy unencrypted TCP traffic.
2. `TLSRoute`s, which control encrypted TCP traffic.

The `HTTPRoute` and `GRPCRoute` resources will not work with Kafka because Kafka does not speak an HTTP-based protocol.

_NOTE: The `HTTPRoute` resource has reached GA in the Gateway API; however, the `TLSRoute` is still in beta. Some advise not using it, but it should be fine as long as you check release notes and test before upgrading!_

## Putting It Into Practice

The rest of this blog post will walk through how to use `TLSRoute`s to access a Strimzi-managed Kafka cluster from outside of your Kubernetes cluster. We will use a [KIND](https://kind.sigs.k8s.io/) cluster, which allows us to run a Kubernetes cluster in docker containers on our local machine.
