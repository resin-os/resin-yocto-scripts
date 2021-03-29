#!/usr/bin/env bash

DOCKER="${DOCKER:-"docker"}"

script_name=$(basename "${0}")
script_dir=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
work_dir="$( cd "${script_dir}/../.." && pwd )"

usage() {
	cat <<EOF
Usage: ${script_name} [OPTIONS]
    -d Device type name
    -a Balena API environment
    -t Balena API token
    -s Shared build directory
    -v BalenaOS variant (dev | prod)
    -b Bitbake arguments
    -i Bitbake targets (default to the device type default, balena-image or balena-image-flasher)
    -g Barys extra arguments
    -h Display usage
    -v Verbose output
EOF
	exit 0
}

source "${script_dir}/balena-lib.inc"

__check_docker() {
    if ! "${DOCKER}" info > /dev/null 2>&1; then
        return 1
    fi
    return 0
}

BUILD_CONTAINER_NAME=yocto-build-$$

docker_build_cleanup() {
	echo "[INFO] $0: Cleanup."

	# Stop docker container
	echo "[INFO] $0: Cleaning up yocto-build container."
	"${DOCKER}" stop $BUILD_CONTAINER_NAME 2> /dev/null || true
	"${DOCKER}" rm --volumes $BUILD_CONTAINER_NAME 2> /dev/null || true

	if [ "$1" = "fail" ]; then
		exit 1
	fi
}
trap 'docker_build_cleanup fail' SIGINT SIGTERM

balena_build_run_barys() {
    local _device_type="${1}"
    local _shared_dir="${2}"
    local _variant="${3}"
    local _token="${4}"
    local _bitbake_args="${5}"
    local _bitbake_targets="${6}"
    local _barys_args="${7}"
    local _docker_run_args="${8:-"--rm"}"
    local _dl_dir
    local _sstate_dir
    local _namespace="${NAMESPACE:-"resin"}"

    [ -z "${_device_type}" ] && echo "Device type is required"  && exit 1
    [ -z "${_shared_dir}" ] && echo "Shared directory path is required"  && exit 1
    [ -z "${_variant}" ] && echo "Variant is required"  && exit 1
    [ -z "${_bitbake_args}" ] && _bitbake_args=""
    [ -z "${_bitbake_targets}" ] && _bitbake_targets=""
    _dl_dir="${_shared_dir}/shared-downloads"
    _sstate_dir="${_shared_dir}/${_device_type}/sstate"
    mkdir -p "${_dl_dir}"
    mkdir -p "${_sstate_dir}"
    [ -n "${_bitbake_args}" ] && _bitbake_args="--bitbake-args ${_bitbake_args}"
    [ -n "${_bitbake_targets}" ] && _bitbake_targets="--bitbake-target ${_bitbake_targets}"

    _token=${_token:-"$(balena_lib_token)"}

    if ! __check_docker; then
	    echo "Docker needs to be installed"
	    exit 1
    fi

    "${DOCKER}" stop $BUILD_CONTAINER_NAME 2> /dev/null || true
    "${DOCKER}" rm --volumes $BUILD_CONTAINER_NAME 2> /dev/null || true
    if ! balena_lib_docker_pull_helper_image "Dockerfile_yocto-build-env" balena_yocto_scripts_revision; then
            exit 1
    fi
    ${DOCKER} run ${__docker_run_args} \
        -v "${work_dir}":/yocto/resin-board \
        -v "${_dl_dir}":/yocto/shared-downloads \
        -v "${_sstate_dir}":/yocto/shared-sstate \
        -v "${SSH_AUTH_SOCK}":/tmp/ssh-agent \
        -e SSH_AUTH_SOCK=/tmp/ssh-agent \
        -e BUILDER_UID="$(id -u)" \
        -e BUILDER_GID="$(id -g)" \
        -e BALENA_TOKEN="${_token}" \
        -e DEVELOPMENT_IMAGE="${_variant}" \
        --name $BUILD_CONTAINER_NAME \
        --privileged \
        "${_namespace}"/yocto-build-env:"${balena_yocto_scripts_revision}" \
        /prepare-and-start.sh \
            --log \
            --machine "${_device_type}" \
            ${_bitbake_args} \
            ${_bitbake_targets} \
            ${_barys_args} \
            --shared-downloads /yocto/shared-downloads \
            --shared-sstate /yocto/shared-sstate \
            --skip-discontinued \
            --rm-work

    balena_lib_docker_remove_helper_images "yocto-build-env"
}

main() {
	local _device_type
	local _api_env
	local _token
	local _shared_dir
	local _variant
	local _bitbake_args
	local _bitbake_targets
	local _barys_args
	## Sanity checks
	if [ ${#} -lt 1 ] ; then
		usage
		exit 1
	else
		while getopts "hv:d:a:t:s:v:b:i:g:" c; do
			case "${c}" in
				d) _device_type="${OPTARG}";;
				a) _api_env="${OPTARG}";;
				t) _token="${OPTARG}";;
				s) _shared_dir="${OPTARG}" ;;
				v) _variant="${OPTARG}" ;;
				b) _bitbake_args="${OPTARG}" ;;
				i) _bitbake_targets="${OPTARG}" ;;
				g) _barys_args="${OPTARG}" ;;
				h) usage;;
				*) usage;exit 1;;
			esac
		done

		_device_type="${_device_type:-"${MACHINE}"}"
		[ -z "${_device_type}" ] && echo "Device type is required" && exit 1

		_api_env="${_api_env:-$(balena_lib_environment)}"
		_token="${_token:-$(balena_lib_token)}"
		_shared_dir="${_shared_dir:-"${YOCTO_DIR}"}"
		[ -z "${_shared_dir}" ] && echo "Shared directory is required" && exit 1
		_variant="${_variant:-"${buildFlavor}"}"
		[ -z "${_variant}" ] && echo "Variant is required" && exit 1

                balena_build_run_barys "${_device_type}" "${_shared_dir}" "${_variant}" "${_token}" "${_bitbake_args}" "${_bitbake_targets}" "${_barys_args}"
	fi
}

main "${@}"