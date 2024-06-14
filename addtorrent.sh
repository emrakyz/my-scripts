#!/bin/dash

n() {
        notify-send "Transmission" "${1}"
}

m() {
        rofi -dmenu -i -l "${1}" -p "${2}"
}

find_id() {
        opts="$(transmission-remote -l | sed -E '1d;$d; s/^ *([0-9]+).*\s{2,}(.+)$/\1 \2/')"
        id="$(printf "%s\n" "${opts}" | m "10" "Torrent List" | hck -Ld ' ' -f1)"
}

add_torrent() {
        MAGNET="$(wl-paste)"

        printf "%s\n" "${MAGNET}" | rg -q '^[0-9a-fA-F]{40}$' && {
                MAGNET="magnet:?xt=urn:btih:${MAGNET}"
        } || {
                printf "%s\n" "${MAGNET}" | rg -q '^magnet:\?xt=urn:btih:[0-9a-fA-F]{40}' || {
                        n "Clipboard not valid"
                        exit
                }
        }

        while read -r tracker; do
                MAGNET="${MAGNET}&tr=${tracker}"
        done < "${XDG_DATA_HOME}/trackers.txt"

        pidof transmission-daemon > "/dev/null" || {
                transmission-daemon
                sleep "3"
        }

        transmission-remote -a "${MAGNET}" &&
                HASH="${MAGNET#*btih:}"
        HASH="${HASH%%&*}"
        n "\"${HASH}\" added."
}

remove_torrent() {
        find_id

        for i in ${id}; do
                i="${i}${id},"
        done

        i=${id%,}

        transmission-remote -t ${i} -r && n "${i} removed"
}

list_torrents() {
        awk_script='NR==1{print $2"   "$3"      "$4"\t "$6"\t"$9} $1~/^[0-9]+$/{print $2"    "$3$4"   "$5" "$6"\t "$8"\t"$11} $1=="Sum:"{print "\n"$1"   "$2$3"\t\t "$5}'

        foot bash -c 'transmission-remote -l | awk '"'${awk_script}'"'; read -r -p "Press enter to quit..."'
}

ch_torrent_prio() {
        find_id

        PRIORITY="$(printf "High\nNormal\nLow" | m "3" "Select Priority")"

        case "${PRIORITY}" in
                "High") transmission-remote -t "${id}" -Bh ;;
                "Normal") transmission-remote -t "${id}" -Bn ;;
                "Low") transmission-remote -t "${id}" -Bl ;;
                *) exit ;;
        esac && n "\"${id}\" priority set to ${PRIORITY}."
}

ch_file_prio() {
        find_id

        sel="$(transmission-remote -t "${id}" -f |
                sed -E '1,2d; s/^[ ]*([0-9]+):[ ]+([^ ]+ +){3}([^ ]+ [^ ]+)[ ]+(.*)/\1 \3 \4/' |
                rofi -dmenu -multi-select | hck -Ld ' ' -f1)"

        PRIORITY="$(printf "High\nNormal\nLow\nNo Download" | m "4" "Priority")"

        for f in ${sel}; do
                i="${i}${f},"
        done

        i=${i%,}

        case "${PRIORITY}" in
                "High") CMD_ARGS="-g ${i} -ph ${i}" ;;
                "Normal") CMD_ARGS="-g ${i} -pn ${i}" ;;
                "Low") CMD_ARGS="-g ${i} -pl ${i}" ;;
                "No Download") CMD_ARGS="-G ${i} -pl ${i}" ;;
                *) exit ;;
        esac

        transmission-remote -t "${id}" ${CMD_ARGS}
        n "Prio ${PRIORITY}: ${i}"
}

start_stop() {
        CHOICE="$(printf "Start\nStop" | m "2" "Action for torrent ${id}")"

        for id in $(find_id); do
                id_INDEX="${id_INDEX}${id},"
        done

        id_INDEX="${id_INDEX%,}"

        case "${CHOICE}" in
                "Start") transmission-remote -t ${id_INDEX} --start && n "${id_INDEX} started" ;;
                "Stop") transmission-remote -t ${id_INDEX} --stop && n "${id_INDEX} stopped" ;;
                *) exit ;;
        esac
}

no_download() {
        find_id
        transmission-remote -t "${id}" -G "all"
}

install_services() {
        n "Installing Prowlarr & Flaresolverr..."
        n "This can take a while..."

        command -v "emerge" > "/dev/null" && {
                {
                        printf "%s\n" '# Needed for flaresolver'
                        printf "%s\n" 'x11-base/xorg-server xvfb minimal'
                } >> /etc/portage/package.use

                doas emerge --ask=no --noreplace "x11-base/xorg-server"

        } || sudo pacman -S "xorg-server-xvfb"

        flare_url="$(curl -s "https://api.github.com/repos/FlareSolverr/FlareSolverr/releases/latest" |
                rg -oP '"browser_download_url": "\K(.*linux_x64.tar.gz)(?=")')"

        prowlarr_url="$(curl -s "https://api.github.com/repos/Prowlarr/Prowlarr/releases/latest" |
                rg -oP '"browser_download_url": "\K(.*linux-core-x64.tar.gz)(?=")')"

        mkdir -p "${HOME}/.local/src"

        curl -L "${flare_url}" | tar -xz -C "${HOME}/.local/src"
        mv -f "${HOME}/.local/src"/*linux_x64 "${HOME}/.local/src/flaresolverr"

        curl -L "${prowlarr_url}" | tar -xz -C "${HOME}/.local/src"
        mv -f "${HOME}/.local/src"/Prowlarr* "${HOME}/.local/src/prowlarr"

        n "Installation finished successfully"
        n "You can run the script again"
        exit
}

search_torrents() {
        [ -f "${HOME}/.local/src/prowlarr/Prowlarr" ] || {
                SELECTION="$(printf "No\nYes" | m "2" "Install Prowlarr & Flaresolverr?")"

                [ "${SELECTION}" = "Yes" ] && install_services || exit
        }

        QUERY="$(printf "" | m "0" "Torrent Search Query")"

        pidof -q flaresolverr || {
                n "Starting Flaresolverr..."
                "${HOME}/.local/src/flaresolverr/flaresolverr" &
        }

        pidof -q Prowlarr || {
                n "Starting Prowlarr..."
                "${HOME}/.local/src/prowlarr/Prowlarr" &
        }

        i="0"
        while [ "${i}" -lt "15" ]; do
                curl -s "http://localhost:9696" > "/dev/null" &&
                        curl -s "http://0.0.0.0:8191" > "/dev/null" && break
                i="$((i + 1))"
                sleep "0.5"
        done

        [ "${i}" -lt "15" ] || n "A service did not start. Check dependencies."

        n "Prowlarr & Flaresolver ready"

        librewolf "http://localhost:9696/search?query=${QUERY}"
}

exit_services() {
        while pidof -s Prowlarr flaresolverr transmission-daemon; do
                killall Prowlarr flaresolverr transmission-daemon
        done
        n "Services are closed"
}

main() {
        CHOICE="$(printf "Add Torrent\nRemove Torrent\nList Torrents\nChange Torrent Priority\nChange File Priority\nStart/Stop\nDisable All Files\nSearch Torrents\nExit Services" | m "9" "Transmission")"

        case "${CHOICE}" in
                "Add Torrent") add_torrent ;;
                "Remove Torrent") remove_torrent ;;
                "List Torrents") list_torrents ;;
                "Change Torrent Priority") ch_torrent_prio ;;
                "Change File Priority") ch_file_prio ;;
                "Start/Stop") start_stop ;;
                "Disable All Files") no_download ;;
                "Search Torrents") search_torrents ;;
                "Exit Services") exit_services ;;
                *) exit ;;
        esac
}

main
