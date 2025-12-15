FROM kalilinux/kali-rolling AS final
ENV DEBIAN_FRONTEND=noninteractive
ARG DEB_RETRIES=5

# Минимально необходимые пакеты (утилиты и зависимости)
RUN set -eux; \
    echo 'deb http://http.kali.org/kali kali-rolling main contrib non-free' > /etc/apt/sources.list; \
    apt-get update -o Acquire::Retries=${DEB_RETRIES}; \
    apt-get install -y --no-install-recommends \
        python3 python3-pip python3-setuptools \
        libpcap0.8 libsqlite3-0 libnl-3-200 libnl-genl-3-200 libcurl4 \
        wireless-tools net-tools iw iproute2 ethtool shtool usbutils pciutils rfkill kmod \
        tshark macchanger sqlite3 ca-certificates \
        aircrack-ng reaver hcxtools hcxdumptool cowpatty pixiewps hashcat \
        ocl-icd-libopencl1 pocl-opencl-icd procps hostapd-mana; \
    airodump-ng-oui-update; \
    rm -rf /var/lib/apt/lists/*

# Дополнительная очистка в финальном образе: убрать неиспользуемые файлы, manpages, локали (опционально)
RUN set -eux; \
    find /usr/local -name "*.la" -delete || true; \
    find /usr/local -name "*.a" -delete || true; \
    rm -rf /usr/local/share/man /usr/local/share/doc /usr/local/include || true; \
    apt-get clean || true; rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

ENV PATH="/usr/local/sbin:/usr/local/bin:${PATH}"
CMD ["/bin/bash"]