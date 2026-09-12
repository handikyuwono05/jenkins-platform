# syntax=docker/dockerfile:1.7
#
# Jenkins controller image: fully declarative (Configuration as Code) with
# Google OAuth 2.0 login. The image is immutable and contains NO secrets --
# secrets are injected at runtime as files under /run/secrets and read by
# JCasC's DockerSecretSource.
#
# The base image is pinned by tag AND digest (supply-chain integrity, OWASP
# A08). Refresh both together with `make base-digest`.
ARG JENKINS_BASE=jenkins/jenkins:2.568.3-lts-jdk21@sha256:c1e4c349365f6d16d88595b2c5f7e8ff39b8ae1d061f62420bac193b4b9616d0

FROM ${JENKINS_BASE}

ARG TZ=Asia/Jakarta
ARG BUILD_REVISION=unknown

LABEL org.opencontainers.image.title="jenkins-platform" \
      org.opencontainers.image.description="Jenkins controller, configured as code, with Google OAuth login" \
      org.opencontainers.image.revision="${BUILD_REVISION}" \
      org.opencontainers.image.licenses="MIT"

# curl is only needed for the container HEALTHCHECK below. Installed
# explicitly so the healthcheck does not depend on what the base image
# happens to ship.
USER root
# DL3008 (pin apt versions) is ignored deliberately: pinning curl to an exact
# Debian version would break every base-image bump, and the base image is
# already pinned by digest, which is where reproducibility is actually anchored.
# hadolint ignore=DL3008
RUN apt-get update \
    && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/*

USER jenkins

# Plugins are resolved at BUILD time, never at runtime: a controller that
# downloads code on boot is not reproducible and not auditable.
COPY --chown=jenkins:jenkins plugins.txt /usr/share/jenkins/ref/plugins.txt
RUN jenkins-plugin-cli --plugin-file /usr/share/jenkins/ref/plugins.txt

# Config lives OUTSIDE $JENKINS_HOME so the persistent volume can never
# shadow or mutate it. JCasC reapplies this on every boot, which means a
# change made through the UI is reverted on restart -- that is the point.
COPY --chown=jenkins:jenkins casc/ /var/jenkins_conf/casc/
COPY --chown=jenkins:jenkins casc-recovery/ /var/jenkins_conf/casc-recovery/
COPY --chown=jenkins:jenkins config/logging.properties /var/jenkins_conf/logging.properties

ENV TZ="${TZ}" \
    CASC_JENKINS_CONFIG=/var/jenkins_conf/casc \
    JAVA_OPTS="-Djenkins.install.runSetupWizard=false \
-Djava.util.logging.config.file=/var/jenkins_conf/logging.properties \
-Duser.timezone=${TZ} \
-XX:MaxRAMPercentage=75.0 \
-XX:+ExitOnOutOfMemoryError"

EXPOSE 8080

# /login is unauthenticated and rendered only once the security realm is
# live, so it proves JCasC applied rather than merely that the JVM booted.
# Exec form: no shell involved, and curl already exits non-zero on failure.
HEALTHCHECK --interval=15s --timeout=5s --start-period=120s --retries=12 \
    CMD ["curl", "-fsS", "-o", "/dev/null", "http://127.0.0.1:8080/login"]
