#!/bin/bash

[ "${UID}" -eq "0" ] || {
        echo "This script must be run as root" >&2
        exit "1"
}

set -Eeo pipefail

GREEN='\e[1;92m' RED='\e[1;91m' BLUE='\e[1;94m'
PURPLE='\e[1;95m' YELLOW='\e[1;93m' NC='\033[0m'
CYAN='\e[1;96m' WHITE='\e[1;97m'

handle_error() {
        error_status="${?}"
        command_line="${BASH_COMMAND}"
        error_line="${BASH_LINENO[0]}"
        log_info r "Error on line ${BLUE}${error_line}${RED}: command ${BLUE}'${command_line}'${RED} exited with status: ${BLUE}${error_status}"
}

trap 'handle_error' ERR RETURN INT

log_info() {
        sleep "0.3"

        case "${1}" in
                g) COLOR="${GREEN}" MESSAGE="DONE!" ;;
                r) COLOR="${RED}" MESSAGE="WARNING!" ;;
                b) COLOR="${BLUE}" MESSAGE="STARTING." ;;
                c) COLOR="${BLUE}" MESSAGE="RUNNING." ;;
        esac

        COLORED_TASK_INFO="${WHITE}(${CYAN}${TASK_NUMBER}${PURPLE}/${CYAN}${TOTAL_TASKS}${WHITE})"
        MESSAGE_WITHOUT_TASK_NUMBER="${2}"

        DATE="$(date "+%Y-%m-%d ${CYAN}/${PURPLE} %H:%M:%S")"

        FULL_LOG="${CYAN}[${PURPLE}${DATE}${CYAN}] ${YELLOW}>>>${COLOR}${MESSAGE}${YELLOW}<<< ${COLORED_TASK_INFO} - ${COLOR}${MESSAGE_WITHOUT_TASK_NUMBER}${NC}"

        { [[ ${1} == "c" ]] && echo -e "\n\n${FULL_LOG}"; } || echo -e "${FULL_LOG}"
}

USER="$(getent passwd | awk -F: '$3 >= 1000 && $3 < 65534 {print $1}' | head -n "1")"

KERNEL_PATH="/boot/EFI/BOOT/BOOTX64.EFI"
NEW_KERNEL="/usr/src/linux/arch/x86/boot/bzImage"

MODULES_DIR="/lib/modules"
CACHE_DIR="/var/cache"
USER_CACHE_DIR="/home/${USER}/.cache"
LOG_DIR="/var/log"
VAR_TMP_DIR="/var/tmp"

FAILED_LOG_DIR="/home/${USER}/failed_builds"

renew_env() {
        env-update && source "/etc/profile"
}

sync_repos() {
        emaint sync -a > "/dev/null" 2>&1
}

update_world() {
        emerge --update "@world" 2>&1 || true
}

update_live() {
        emerge "@live-rebuild" 2>&1 || true
        emerge @preserved-rebuild || true
}

remove_unneeded() {
        CLEAN_DELAY="0" emerge --depclean -q --verbose=n > "/dev/null" 2>&1 || true
}

create_logs() {
        rm -rfv "${FAILED_LOG_DIR}"
        mkdir -pv "${FAILED_LOG_DIR}"
}

update_kernel() {
        DIR_COUNT="$(find /usr/src/ -maxdepth "1" -type d -name 'linux-*' | wc -l)"

        [ "${DIR_COUNT}" -gt "1" ] || {
                echo -e "${BLUE}There is only one linux directory. The function stops...${NC}"
                KERNEL_IS_UPDATED="0"
                return
        }

        KERNEL_DIR="$(find "/usr/src" -maxdepth "1" -type "d" -name 'linux-*' | sort -rV | head -n "1")"

        echo -e "${GREEN}New kernel directory:${CYAN} ${KERNEL_DIR} ${NC}"

        OLD_KERNEL_DIR="$(find "/usr/src" -maxdepth "1" -type "d" -name 'linux-*' | sort -rV | head -n "2" | tail -n "1")"

        echo -e "${GREEN}Old kernel directory:${CYAN} ${OLD_KERNEL_DIR} ${NC}"

        export LLVM="1" LLVM_IAS="1" CFLAGS="-O3 -march=native -pipe" KCFLAGS="-O3 -march=native -pipe"

        cp -fv "${OLD_KERNEL_DIR}/.config" "${KERNEL_DIR}"

        make -C "${KERNEL_DIR}" "olddefconfig" > "/dev/null" 2>&1
        make -C "${KERNEL_DIR}" -j"$(nproc)" > "/dev/null" 2>&1
        make -C "${KERNEL_DIR}" "modules_install" > "/dev/null" 2>&1

        cp -fv "${NEW_KERNEL}" "${KERNEL_PATH}"

        echo -e "${GREEN}New kernel${CYAN} ${NEW_KERNEL} ${GREEN}has been copied to${CYAN} ${KERNEL_PATH}.${NC}"

        rm -rf "${OLD_KERNEL_DIR}"

        echo -e "${GREEN}Old kernel directory${CYAN} ${OLD_KERNEL_DIR} ${GREEN}has been deleted.${NC}"
}

update_nvidia() {
        grep -q 'VIDEO_CARDS="nvidia"' "/etc/portage/make.conf" || {
                echo "Not using Nvidia GPU."
                return
        }
        [[ "${KERNEL_IS_UPDATED}" == "0" ]] && {
                echo -e "${BLUE}The kernel has not been updated. Skipping Nvidia drivers...${NC}"
                return
        }
        emerge "x11-drivers/nvidia-drivers" > "/dev/null" 2>&1
}

copy_failed_logs() {
        while IFS= read -r pkg; do
                log_path="/var/tmp/portage/${pkg}/temp/build.log"
                safe_pkg_name="$(echo "${pkg}" | tr '/' '_')"
                [ -f "${log_path}" ] && cp "${log_path}" "${FAILED_LOG_DIR}/${safe_pkg_name}.log"
        done < "${FAILED_PACKAGES}" || true

        chown -R "${USER}":"${USER}" "/home/${USER}"
}

clean_old_modules() {
        find "${MODULES_DIR}" -mindepth "1" -maxdepth "1" -type "d" | sort -V | head -n "-1" | xargs rm -rf
}

clean_temp_files() {
        rm -rf "${CACHE_DIR:?}"/* "${LOG_DIR:?}"/* "${VAR_TMP_DIR:?}"/*
}

clean_user_cache() {
        find "${USER_CACHE_DIR}" -mindepth "1" -maxdepth "1" \( -name 'wal' -o -name 'youtube_channels' \) -prune -o -print0 | xargs -0 rm -rf
}

run_fstrim() {
        fstrim -Av
}

handle_shutdown() {
        echo -e "${GREEN}The system will shutdown."

        delay_shutdown="$(echo -e "No\nYes" | rofi -dmenu -l "2" -p "Want to delay shutdown?")"

        [[ "${delay_shutdown}" == "Yes" ]] && {
                while true; do
                        delay_amount="$(echo "" | rofi -dmenu -l "0" -p "Amount in minutes:")"

                        [[ "${delay_amount}" ]] || {
                                echo -e "Shutdown not delayed. Shutting down now."
                                openrc-shutdown -p "now"
                                break
                        }

                        [[ "${delay_amount}" =~ ^[0-9]+$ ]] || {
                                notify-send "Invalid input. Please enter a number."
                                continue
                        }

                        notify-send "Shutdown delayed by ${delay_amount} minutes."
                        sleep "$((delay_amount * 60))"

                        delay_shutdown="$(echo -e "No\nYes" | rofi -dmenu -l "2" -p "Want to delay shutdown?")"
                        [[ "${delay_shutdown}" == "No" ]] && {
                                openrc-shutdown -p "now"
                                break
                        }
                done
        } || openrc-shutdown -p "now"
}

main() {
        declare -A "tasks"

        tasks["renew_env"]="Renew the environment.
		       Environment renewed."

        tasks["sync_repos"]="Sync the Gentoo repositories.
		       Gentoo repositories synced."

        tasks["update_world"]="Update the world.
		         The world updated."

        tasks["update_live"]="Update live packages.
                        Live packages updated."

        tasks["remove_unneeded"]="Remove unneeded packages.
                            Unneeded packages removed."

        tasks["create_logs"]="Create logs for failed packages.
                        Logs for failed packages created."

        tasks["update_kernel"]="Update the kernel.
		          The kernel is ready."

        tasks["update_nvidia"]="Recompile Nvidia drivers.
		          Nvidia drivers ready."

        tasks["copy_failed_logs"]="Copy failed build logs.
		             Failed build logs copied."

        tasks["clean_old_modules"]="Clean old kernel modules.
			      Old kernel modules cleaned."

        tasks["clean_temp_files"]="Clean temporary files.
                             Temporary files cleaned."

        tasks["clean_user_cache"]="Clean the user cache.
                             The user cache cleaned."

        tasks["run_fstrim"]="Trim the filesystem.
                       Filesystem trimmed."

        task_order=("renew_env" "sync_repos" "update_world" "update_live" "remove_unneeded"
                "create_logs" "update_kernel" "update_nvidia" "copy_failed_logs"
                "clean_old_modules" "clean_temp_files" "clean_user_cache" "run_fstrim")

        TOTAL_TASKS="${#tasks[@]}"
        TASK_NUMBER="1"

        trap '[[ -n "${log_pid}" ]] && kill "${log_pid}" 2> "/dev/null"' EXIT INT QUIT TERM ERR RETURN

        for function in "${task_order[@]}"; do
                description="${tasks[${function}]}"
                description="${description%%$'\n'*}"

                done_message="$(echo "${tasks[${function}]}" | tail -n "1" | sed 's/^[[:space:]]*//g')"

                log_info b "${description}"

                (
                        sleep "120"
                        while true; do
                                log_info c "${description}"
                                sleep "120"
                        done || true
                ) &
                log_pid="${!}"

                "${function}"
                log_info g "${done_message}"

                [[ "${TASK_NUMBER}" == "${TOTAL_TASKS}" ]] && {
                        log_info g "All tasks completed."
                        kill "${log_pid}" 2> "/dev/null" || true
                        break
                }

                kill "${log_pid}" 2> "/dev/null" || true

                ((TASK_NUMBER++))
        done

        [[ "${1}" == "-f" ]] && openrc-shutdown -p "now" || "handle_shutdown"
}

main "${@}"
