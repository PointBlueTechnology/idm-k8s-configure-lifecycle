# Job image for the eDirectory backup CronJob.
# Provides bash, ssh, base64, and kubectl. Build and load it where the cluster
# can pull IMAGE_VAULT_BACKUP (air-gapped labs: docker save/load or a local registry).
#
#   docker build -t edir-backup:local images/edir-backup
FROM alpine:3.20

ARG KUBECTL_VERSION=v1.32.2
ARG TARGETARCH=amd64

RUN apk add --no-cache bash openssh-client ca-certificates coreutils wget \
    && wget -q -O /usr/local/bin/kubectl \
      "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl" \
    && chmod 0755 /usr/local/bin/kubectl \
    && kubectl version --client=true

USER 0
ENTRYPOINT ["/bin/bash"]
