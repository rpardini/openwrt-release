##### Args passed by GHA:
# OPENWRT_GIT_URL=${{ matrix.git_url }}
# OPENWRT_BRANCH=${{ matrix.branch }}
# RELEASE_ID=${{matrix.id}}
# OPENWRT_REVISION==${{ steps.gitinfo.outputs.sha1 }}
# OPENWRT_CONFIG=${{ matrix.config }}
# RELEASE_VERSION=${{needs.prepare.outputs.created}}
FROM debian:stable AS build

# Install dependencies for building OpenWRT, plus utils for compression and randomizing MBR label-id
ENV DEBIAN_FRONTEND=noninteractive
RUN apt -y update && apt -y install build-essential git make tree unzip wget file curl gawk python3 python3-dev rsync \
                                    libncurses5-dev python3-pyelftools python3-setuptools swig golang-go \
                                    fdisk zstd

# Use a regular user for building, as OpenWRT can't be built as root
RUN useradd -m openwrt && mkdir -p /src /dist && chown -R openwrt /src /dist
USER openwrt

WORKDIR /src
ARG OPENWRT_GIT_URL
ARG OPENWRT_BRANCH
RUN git clone --branch ${OPENWRT_BRANCH} ${OPENWRT_GIT_URL} openwrt

WORKDIR /src/openwrt

### <TO-BE-REPLAYED>
RUN ./scripts/feeds update -a && ./scripts/feeds install -a

ARG OPENWRT_CONFIG
RUN cp -v ${OPENWRT_CONFIG} .config && make defconfig

# Download sources; as this can fail due to network issues, we retry a few times with decreasing parallelism
RUN make download -j4 || make download -j2 || make download || make download

# Now lets build parts of OpenWRT, we can't build everything in one go as caches would grow too big.
# For each step, first do a parallel build with nproc+2; if it fails, build with -j1 V=s to get more verbose output so we know what broke in the GHA logs.

# Build the toolchain first
RUN make -j$(($(nproc)+2)) toolchain/install  || make toolchain/install -j1 V=s

# Build the kernel
RUN make -j$(($(nproc)+2)) target/linux/compile || make target/linux/compile -j1 V=s

# Build the packages
RUN make -j$(($(nproc)+2)) package/compile || make package/compile -j1 V=s

# Build the firmware
RUN make -j$(($(nproc)+2)) || make -j1 V=s
### </TO-BE-REPLAYED>

## Ok, now we've a built firmware. Let's fetch from the repo and checkout the specific commit, then build everything again.
# This should now massively hit on the caches previously built and only update the changed parts.
ARG OPENWRT_REVISION
RUN git fetch origin ${OPENWRT_BRANCH} && git checkout ${OPENWRT_REVISION}

### <REPLAYED>
RUN ./scripts/feeds update -a && ./scripts/feeds install -a

RUN cp -v ${OPENWRT_CONFIG} .config && make defconfig

# Download sources; as this can fail due to network issues, we retry a few times with decreasing parallelism
RUN make download -j4 || make download -j2 || make download || make download

# Now lets build parts of OpenWRT, we can't build everything in one go as caches would grow too big.
# For each step, first do a parallel build with nproc+2; if it fails, build with -j1 V=s to get more verbose output so we know what broke in the GHA logs.

# Build the toolchain first
RUN make -j$(($(nproc)+2)) toolchain/install  || make toolchain/install -j1 V=s

# Build the kernel
RUN make -j$(($(nproc)+2)) target/linux/compile || make target/linux/compile -j1 V=s

# Build the packages
RUN make -j$(($(nproc)+2)) package/compile || make package/compile -j1 V=s

# Build the firmware
RUN make -j$(($(nproc)+2)) || make -j1 V=s
### </REPLAYED>

# Decompress gzip, random MBR label-id, and compress with zstd
RUN cp -v bin/targets/*/*/*.img.gz /dist && \
    ls -lah /dist/*.img.gz && \
    gunzip /dist/*.img.gz || true && \
    echo 'before: ' && sfdisk -d /dist/*.img && \
    LABEL_ID="$(bash -c 'echo $(( RANDOM * 32768 + RANDOM ))')" && echo "random: $LABEL_ID" && \
    sfdisk --disk-id /dist/*.img "${LABEL_ID}" && \
    echo 'after:' && sfdisk -d /dist/*.img && \
    zstdmt --rm /dist/*.img && ls -lah /dist/*.img*

# Finally the output stage
FROM alpine:3
WORKDIR /out
COPY --from=build /dist/* /out/
