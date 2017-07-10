#!/bin/bash

cd "$(dirname "${0}")"
BUILD_DIR="$(pwd)"
cd ->/dev/null

# Homebrew bootstrapping information
: ${HB_BOOTSTRAP_GIST_URL:="https://gist.githubusercontent.com/toonetown/48101686e509fda81335/raw"}
HB_BOOTSTRAP="t:*toonetown/android b:android-ndk 
              b:autoconf b:automake b:libtool
              t:toonetown/extras b:toonetown-extras s:toonetown-extras b:android-env"

# Overridable build locations
: ${DEFAULT_OPENSSL_DIST:="${BUILD_DIR}/openssl"}
: ${OBJDIR_ROOT:="${BUILD_DIR}/target"}
: ${CONFIGS_DIR:="${BUILD_DIR}/configs"}
: ${MAKE_BUILD_PARALLEL:=$(sysctl -n hw.ncpu)}

# Options for OpenSSL
: ${COMMON_OPENSSL_BUILD_OPTIONS:="no-shared enable-static-engine no-asm no-hw"}
: ${OPENSSL_BUILD_OPTIONS:=""}

# Include files which are platform-specific
PLATFORM_SPECIFIC_HEADERS="include/openssl/opensslconf.h"

list_arch() {
    if [ -z "${1}" ]; then
        PFIX="${CONFIGS_DIR}/setup-*"
    else
        PFIX="${CONFIGS_DIR}/setup-${1}"
    fi
    ls -m ${PFIX}.*.sh 2>/dev/null | sed "s#${CONFIGS_DIR}/setup-\(.*\)\.sh#\1#" | \
                         tr -d '\n' | \
                         sed -e 's/ \+/ /g' | sed -e 's/^ *\(.*\) *$/\1/g'
}

list_plats() {
    for i in $(list_arch | sed -e 's/,//g'); do
        echo "${i}" | cut -d'.' -f1
    done | sort -u
}

print_usage() {
    while [ $# -gt 0 ]; do
        echo "${1}" >&2
        shift 1
        if [ $# -eq 0 ]; then echo "" >&2; fi
    done
    echo "Usage: ${0} [/path/to/openssl-dist] "                                             >&2
    echo "            <plat.arch|plat|'combine-headers'|'bootstrap'|'clean'>"               >&2
    echo ""                                                                                 >&2
    echo "\"/path/to/openssl-dist\" is optional and defaults to:"                           >&2
    echo "    \"${DEFAULT_OPENSSL_DIST}\""                                                  >&2
    echo ""                                                                                 >&2
    echo "Possible plat.arch combinations are:"                                             >&2
    for p in $(list_plats); do
        echo "    ${p}:"                                                                    >&2
        echo "        $(list_arch ${p})"                                                    >&2
        echo ""                                                                             >&2
    done
    echo "If you specify just a plat, then *all* architectures will be built for that"      >&2
    echo "platform, and the resulting libraries will be \"lipo\"-ed together to a single"   >&2
    echo "fat binary (if supported)."                                                       >&2
    echo ""                                                                                 >&2
    echo "When specifying clean, you may optionally include a plat or plat.arch to clean,"  >&2
    echo "i.e. \"${0} clean macosx.i386\" to clean only the i386 architecture on Mac OS X"  >&2
    echo "or \"${0} clean ios\" to clean all ios builds."                                   >&2
    echo ""                                                                                 >&2
    return 1
}

do_bootstrap() {
    curl -sSL "${HB_BOOTSTRAP_GIST_URL}" | /bin/bash -s -- ${HB_BOOTSTRAP}
}

do_build_openssl() {
    TARGET="${1}"
    OUTPUT_ROOT="${2}"
    BUILD_ROOT="${OUTPUT_ROOT}/build/openssl"

    [ -n "${PLATFORM_DEFINITION}" ] || {
        echo "PLATFORM_DEFINITION is not set for ${TARGET}"
        return 1
    }
    [ -n "${OPENSSL_CONFIGURE_NAME}" ] || {
        echo "OPENSSL_CONFIGURE_NAME is not set for ${TARGET}"
        return 1
    }

    [ -d "${BUILD_ROOT}" -a -f "${BUILD_ROOT}/Configure" ] || {
        echo "Creating build directory for '${TARGET}'..."
        mkdir -p "$(dirname "${BUILD_ROOT}")" || return $?
        cp -r "${PATH_TO_OPENSSL_DIST}" "${BUILD_ROOT}" || return $?
    }
    
    if [ "${BUILD_ROOT}/Makefile" -ot "${BUILD_ROOT}/Makefile.org" ]; then
        echo "Configuring OpenSSL build directory for '${TARGET}'..."
        cd "${BUILD_ROOT}" || return $?
        [ -n "${OPENSSL_PRECONFIGURE}" ] && {
            [ -x "${OPENSSL_PRECONFIGURE}" ] || { echo "${OPENSSL_PRECONFIGURE} does not exist"; return 1; }
            "${OPENSSL_PRECONFIGURE}" || return $?
        }
        ./Configure ${OPENSSL_CONFIGURE_NAME} \
                    ${COMMON_OPENSSL_BUILD_OPTIONS} \
                    ${OPENSSL_BUILD_OPTIONS} \
                    --openssldir="${OUTPUT_ROOT}" || {
            rm -f "${BUILD_ROOT}/Makefile"
            return 1
        }
        cd ->/dev/null
    fi

    cd "${BUILD_ROOT}"
    echo "Building OpenSSL architecture '${TARGET}'..."
    
    # Generate the project and build (and clean up empty cruft directories)
    make -j ${MAKE_BUILD_PARALLEL} build_apps && make install_sw
    ret=$?
    rmdir "${OUTPUT_ROOT}"/{bin,certs,misc,private,lib/engines,lib/pkgconfig} >/dev/null 2>&1
    
    # Update platform-specific headers
    if [ ${ret} -eq 0 ]; then
        for h in ${PLATFORM_SPECIFIC_HEADERS}; do
            echo "Updating header '${h}' for ${TARGET}..."
            echo "#if ${PLATFORM_DEFINITION}" > "${OUTPUT_ROOT}/${h}.tmp"
            cat "${OUTPUT_ROOT}/${h}" >> "${OUTPUT_ROOT}/${h}.tmp"
            echo "#endif" >> "${OUTPUT_ROOT}/${h}.tmp"
            mv "${OUTPUT_ROOT}/${h}.tmp" "${OUTPUT_ROOT}/${h}" || return $?
        done
    fi
    cd ->/dev/null
    return ${ret}
}

do_build() {
    TARGET="${1}"; shift
    PLAT="$(echo "${TARGET}" | cut -d'.' -f1)"
    ARCH="$(echo "${TARGET}" | cut -d'.' -f2)"
    CONFIG_SETUP="${CONFIGS_DIR}/setup-${TARGET}.sh"
    
    # Clean here - in case we pass a "clean" command
    if [ "${1}" == "clean" ]; then do_clean ${TARGET}; return $?; fi

    if [ -f "${CONFIG_SETUP}" -a "${PLAT}" != "${ARCH}" ]; then
        # Load configuration files
        [ -f "${CONFIGS_DIR}/setup-${PLAT}.sh" ] && {
            source "${CONFIGS_DIR}/setup-${PLAT}.sh"    || return $?
        }
        source "${CONFIG_SETUP}" && source "${GEN_SCRIPT}" || return $?
        do_build_openssl ${TARGET} "${OBJDIR_ROOT}/objdir-${TARGET}" || return $?
        
        return $?
    elif [ -n "${TARGET}" -a -n "$(list_arch ${TARGET})" ]; then
        PLATFORM="${TARGET}"

        # Load configuration file for the platform
        [ -f "${CONFIGS_DIR}/setup-${PLATFORM}.sh" ] && {
            source "${CONFIGS_DIR}/setup-${PLATFORM}.sh"    || return $?
        }
        
        if [ -n "${LIPO_PATH}" ]; then
            echo "Building fat binary for platform '${PLATFORM}'..."
        else
            echo "Building all architectures for platform '${PLATFORM}'..."
        fi

        COMBINED_ARCHS="$(list_arch ${PLATFORM} | sed -e 's/,//g')"
        for a in ${COMBINED_ARCHS}; do
            do_build ${a} || return $?
        done
        
        # Combine platform-specific headers
        COMBINED_ROOT="${OBJDIR_ROOT}/objdir-${PLATFORM}"
        mkdir -p "${COMBINED_ROOT}" || return $?
        cp -r ${COMBINED_ROOT}.*/include ${COMBINED_ROOT} || return $?
        
        for h in ${PLATFORM_SPECIFIC_HEADERS}; do
            echo "Combining header '${h}'..."
            if [ -f "${COMBINED_ROOT}/${h}" ]; then
                rm ${COMBINED_ROOT}/${h} || return $?
                for a in ${COMBINED_ARCHS}; do
                    cat "${OBJDIR_ROOT}/objdir-${a}/${h}" >> "${COMBINED_ROOT}/${h}" || return $?
                done
            fi
        done

        if [ -n "${LIPO_PATH}" ]; then
            # Set up variables to get our libraries to lipo
            PLATFORM_DIRS="$(find ${OBJDIR_ROOT} -type d -name "objdir-${PLATFORM}.*" -depth 1)"
            PLATFORM_LIBS="$(find ${PLATFORM_DIRS} -type d -name "lib" -depth 1)"
            FAT_OUTPUT="${COMBINED_ROOT}/lib"

            mkdir -p "${FAT_OUTPUT}" || return $?
            for l in $(find ${PLATFORM_LIBS} -type f -name '*.a' -exec basename {} \; | sort -u); do
                echo "Running lipo for library '${l}'..."
                ${LIPO_PATH} -create $(find ${PLATFORM_LIBS} -type f -name "${l}") -output "${FAT_OUTPUT}/${l}"
            done
        fi
    elif [ "${TARGET}" == "combine-headers" ]; then
        COMBINED_ROOT="${OBJDIR_ROOT}/objdir-headers"
        rm -rf "${COMBINED_ROOT}"
        mkdir -p "${COMBINED_ROOT}" || return $?
        COMBINED_PLATS="$(list_plats)"
        for p in ${COMBINED_PLATS}; do
            if [ -d "${OBJDIR_ROOT}/objdir-${p}/include" ]; then
                cp -r "${OBJDIR_ROOT}/objdir-${p}/include" ${COMBINED_ROOT} || return $?
            else
                echo "Platform ${p} has not been built"
                return 1
            fi
        done
        for h in ${PLATFORM_SPECIFIC_HEADERS}; do
            echo "Combining header '${h}'..."
            if [ -f "${COMBINED_ROOT}/${h}" ]; then
                rm ${COMBINED_ROOT}/${h} || return $?
                for p in ${COMBINED_PLATS}; do
                    if [ -f "${OBJDIR_ROOT}/objdir-${p}/${h}" ]; then
                        cat "${OBJDIR_ROOT}/objdir-${p}/${h}" >> "${COMBINED_ROOT}/${h}" || return $?
                    fi
                done
            fi
        done    
    else
        print_usage "Missing/invalid target '${TARGET}'"
    fi
    return $?
}

do_clean() {
    if [ -n "${1}" ]; then
        echo "Cleaning up ${1} builds in \"${OBJDIR_ROOT}\"..."
        rm -rf "${OBJDIR_ROOT}/objdir-${1}" "${OBJDIR_ROOT}/objdir-${1}."*
    else
        echo "Cleaning up all builds in \"${OBJDIR_ROOT}\"..."
        rm -rf "${OBJDIR_ROOT}/objdir-"*  
    fi
    
    # Remove some leftovers (an empty OBJDIR_ROOT)
    rmdir "${OBJDIR_ROOT}" >/dev/null 2>&1
    return 0
}

# Calculate the path to the openssl-dist repository
if [ -d "${1}" ]; then
    cd "${1}"
    PATH_TO_OPENSSL_DIST="$(pwd)"
    cd ->/dev/null
    shift 1
else
    PATH_TO_OPENSSL_DIST="${DEFAULT_OPENSSL_DIST}"
fi

[ -d "${PATH_TO_OPENSSL_DIST}" -a -f "${PATH_TO_OPENSSL_DIST}/Configure" ] || {
    print_usage "Invalid OpenSSL directory:" "    \"${PATH_TO_OPENSSL_DIST}\""
    exit $?
}

# Call bootstrap if that's what we specified
if [ "${1}" == "bootstrap" ]; then
    do_bootstrap ${2}
    exit $?
fi

# Call the appropriate function based on target
TARGET="${1}"; shift
case "${TARGET}" in
    "clean")
        do_clean $@
        ;;
    *)
        do_build ${TARGET} $@
        ;;
esac
exit $?
