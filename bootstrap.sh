#!/usr/bin/env bash
# ============================================================
#  bootstrap.sh — поднять рабочее окружение ОДНОЙ командой.
#  Плейбук встроен прямо внутрь этого файла, ничего больше не нужно.
#
#  Запуск на чистой Manjaro/Arch (под обычным пользователем, НЕ root):
#    curl -fsSL https://raw.githubusercontent.com/asetdak/workstation-setup/main/bootstrap.sh | bash
#
#  Что делает:
#    1. ставит git и ansible
#    2. ставит нужные ansible-коллекции
#    3. разворачивает встроенный плейбук во временный файл
#    4. запускает его (спросит sudo-пароль один раз)
# ============================================================

set -euo pipefail

echo ">>> [1/4] Обновляю систему, ставлю git + ansible..."
sudo pacman -Syu --needed --noconfirm git ansible

echo ">>> [2/4] Ставлю ansible-коллекции..."
ansible-galaxy collection install community.general kewlfft.aur community.libvirt

echo ">>> [3/4] Разворачиваю встроенный плейбук..."
PLAYBOOK_FILE="$(mktemp /tmp/setup.XXXXXX.yml)"
cat > "$PLAYBOOK_FILE" <<'PLAYBOOK_EOF'
---
- name: Setup personal workstation (Manjaro KDE)
  hosts: localhost
  connection: local
  gather_facts: true

  vars:
    target_user: "{{ ansible_user_id }}"

    pacman_packages:
      - git
      - htop
      - fastfetch
      - fzf
      - micro
      - nano-syntax-highlighting
      - 7zip
      - rsync
      - wget
      - nmap
      - mtr
      - traceroute
      - wireguard-tools
      - openssh
      - sshfs
      - filezilla
      - freerdp
      - networkmanager-l2tp
      - networkmanager-openvpn
      - networkmanager-openconnect
      - networkmanager-vpnc
      - qemu-full
      - virt-manager
      - virt-viewer
      - libvirt
      - edk2-ovmf
      - dnsmasq
      - vde2
      - openbsd-netcat
      - docker
      - docker-compose
      - code
      - nodejs-lts-iron
      - npm
      - yarn
      - nvm
      - python-pip
      - python-virtualenv
      - pyenv
      - firefox
      - qbittorrent
      - telegram-desktop
      - discord
      - libreoffice-still
      - okular
      - flameshot
      - spectacle
      - timeshift

    aur_packages:
      - google-chrome
      - onlyoffice-desktopeditors
      - anydesk-bin
      - claude-desktop-bin
      - winbox
      - bongo-cat

  tasks:
    - name: Обновить базу pacman
      become: true
      community.general.pacman:
        update_cache: true

    - name: Установить пакеты из официальных репозиториев (по одному, не падая)
      become: true
      community.general.pacman:
        name: "{{ item }}"
        state: present
      loop: "{{ pacman_packages }}"
      register: pacman_results
      failed_when: false

    - name: Проверить наличие yay
      ansible.builtin.command: which yay
      register: yay_check
      changed_when: false
      failed_when: false

    - name: Установить зависимости для сборки yay (base-devel, git, go)
      become: true
      community.general.pacman:
        name:
          - base-devel
          - git
          - go
        state: present
      when: yay_check.rc != 0

    - name: Собрать yay из AUR (если отсутствует)
      ansible.builtin.shell: |
        cd /tmp
        rm -rf yay
        git clone https://aur.archlinux.org/yay.git
        cd yay
        makepkg -si --noconfirm
      args:
        creates: /usr/bin/yay
      when: yay_check.rc != 0

    - name: Установить пакеты из AUR через yay (по одному, не падая)
      kewlfft.aur.aur:
        name: "{{ item }}"
        use: yay
        state: present
      loop: "{{ aur_packages }}"
      register: aur_results
      failed_when: false
      become: false

    - name: Включить и запустить docker
      become: true
      ansible.builtin.systemd:
        name: docker
        enabled: true
        state: started
      failed_when: false
      failed_when: false

    - name: Добавить пользователя в группу docker
      become: true
      ansible.builtin.user:
        name: "{{ target_user }}"
        groups: docker
        append: true

    - name: Включить и запустить libvirtd
      become: true
      ansible.builtin.systemd:
        name: libvirtd
        enabled: true
        state: started
      failed_when: false
      failed_when: false

    - name: Добавить пользователя в группу libvirt
      become: true
      ansible.builtin.user:
        name: "{{ target_user }}"
        groups: libvirt
        append: true

    - name: Включить автозапуск дефолтной сети libvirt
      become: true
      community.libvirt.virt_net:
        name: default
        autostart: true
        state: active
      failed_when: false

    - name: Собрать список пакетов, которые НЕ установились
      ansible.builtin.set_fact:
        failed_pkgs: >-
          {{
            (pacman_results.results | default([]) | selectattr('failed','defined') | selectattr('failed') | map(attribute='item') | list)
            +
            (aur_results.results | default([]) | selectattr('failed','defined') | selectattr('failed') | map(attribute='item') | list)
          }}

    - name: Показать итог
      ansible.builtin.debug:
        msg: >-
          {{ 'Все пакеты установлены успешно.'
             if (failed_pkgs | length == 0)
             else ('НЕ установились: ' + (failed_pkgs | join(', ')) + ' — проверь имена в репозиториях.') }}
PLAYBOOK_EOF

echo ">>> [4/4] Запускаю плейбук..."

# yay при сборке AUR-пакетов докачивает зависимости через sudo/pacman, но в
# неинтерактивном режиме ему некому ввести пароль. На время прогона временно
# разрешаем текущему пользователю sudo без пароля, по завершении убираем.
SUDOERS_FILE="/etc/sudoers.d/99-bootstrap-temp"
echo ">>> Введи sudo-пароль (один раз, для настройки автоматической установки):"
sudo bash -c "echo '$(whoami) ALL=(ALL) NOPASSWD: ALL' > '$SUDOERS_FILE' && chmod 440 '$SUDOERS_FILE'"

# гарантируем снятие временного правила даже если плейбук упадёт
cleanup() {
  sudo rm -f "$SUDOERS_FILE"
  echo ">>> Временное правило sudo убрано."
}
trap cleanup EXIT

ansible-playbook "$PLAYBOOK_FILE"

rm -f "$PLAYBOOK_FILE"

echo ""
echo "============================================================"
echo " Готово. ВЫЙДИ из сессии и зайди заново (или перезагрузись),"
echo " чтобы подхватились группы docker и libvirt."
echo "============================================================"
