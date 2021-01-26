#!/usr/bin/env bash

set -eo pipefail

passbolt_config="/etc/passbolt"
gpg_private_key="${PASSBOLT_GPG_SERVER_KEY_PRIVATE:-$passbolt_config/gpg/serverkey_private.asc}"
gpg_public_key="${PASSBOLT_GPG_SERVER_KEY_PUBLIC:-$passbolt_config/gpg/serverkey.asc}"

ssl_key='/etc/ssl/certs/certificate.key'
ssl_cert='/etc/ssl/certs/certificate.crt'

deprecation_message=""

export GNUPGHOME="/var/lib/passbolt/.gnupg"

entropy_check() {
  local entropy_avail

  entropy_avail=$(cat /proc/sys/kernel/random/entropy_avail)

  if [ "$entropy_avail" -lt 2000 ]; then

    cat <<EOF
==================================================================================
  Your entropy pool is low. This situation could lead GnuPG to not
  be able to create the gpg serverkey so the container start process will hang
  until enough entropy is obtained.
  Please consider installing rng-tools and/or virtio-rng on your host as the
  preferred method to generate random numbers using a TRNG.
  If rngd (rng-tools) does not provide enough or fast enough randomness you could
  consider installing haveged as a helper to speed up this process.
  Using haveged as a replacement for rngd is not recommended. You can read more
  about this topic here: https://lwn.net/Articles/525459/
==================================================================================
EOF
  fi
}

gpg_gen_key() {
  key_email="${PASSBOLT_KEY_EMAIL:-passbolt@yourdomain.com}"
  key_name="${PASSBOLT_KEY_NAME:-Passbolt default user}"
  key_length="${PASSBOLT_KEY_LENGTH:-2048}"
  subkey_length="${PASSBOLT_SUBKEY_LENGTH:-2048}"
  expiration="${PASSBOLT_KEY_EXPIRATION:-0}"

  entropy_check

  su -c "gpg --homedir $GNUPGHOME --batch --no-tty --gen-key <<EOF
    Key-Type: default
		Key-Length: $key_length
		Subkey-Type: default
		Subkey-Length: $subkey_length
    Name-Real: $key_name
    Name-Email: $key_email
    Expire-Date: $expiration
    %no-protection
		%commit
EOF" -ls /bin/bash www-data

  su -c "gpg --homedir $GNUPGHOME --armor --export-secret-keys $key_email > $gpg_private_key" -ls /bin/bash www-data
  su -c "gpg --homedir $GNUPGHOME --armor --export $key_email > $gpg_public_key" -ls /bin/bash www-data
}

gpg_import_key() {
  su -c "gpg --homedir $GNUPGHOME --batch --import $gpg_public_key" -ls /bin/bash www-data
  su -c "gpg --homedir $GNUPGHOME --batch --import $gpg_private_key" -ls /bin/bash www-data
}

gen_ssl_cert() {
  openssl req -new -newkey rsa:4096 -days 365 -nodes -x509 \
    -subj '/C=FR/ST=Denial/L=Springfield/O=Dis/CN=www.passbolt.local' \
    -keyout $ssl_key -out $ssl_cert
}

install() {

  if [ ! -f "$passbolt_config/app.php" ]; then
    su -c "cp $passbolt_config/app.default.php $passbolt_config/app.php" -s /bin/bash www-data
  fi

  if [ -z "${PASSBOLT_GPG_SERVER_KEY_FINGERPRINT+xxx}" ] && [ ! -f  "$passbolt_config/passbolt.php" ]; then
    gpg_auto_fingerprint="$(su -c "gpg --homedir $GNUPGHOME --list-keys --with-colons ${PASSBOLT_KEY_EMAIL:-passbolt@yourdomain.com} |grep fpr |head -1| cut -f10 -d:" -ls /bin/bash www-data)"
    export PASSBOLT_GPG_SERVER_KEY_FINGERPRINT=$gpg_auto_fingerprint
  fi

  su -c '/usr/share/php/passbolt/bin/cake passbolt install --no-admin' -s /bin/bash www-data || su -c '/usr/share/php/passbolt/bin/cake passbolt migrate' -s /bin/bash www-data && echo "Enjoy! ☮"
}

email_cron_job() {
  cron_task='/etc/cron.d/passbolt_email'
  declare -p | grep -Ev 'BASHOPTS|BASH_VERSINFO|EUID|PPID|SHELLOPTS|UID' > /etc/environment
  if [ ! -f "$cron_task" ]; then
    echo "* * * * * su -c \"source /etc/environment ; /var/www/passbolt/bin/cake EmailQueue.sender\" -s /bin/bash www-data >> /var/log/cron.log 2>&1" >> $cron_task
    crontab /etc/cron.d/passbolt_email
  fi
}

create_deprecation_message() {
  deprecation_message+="\033[33;5;7mWARNING: $1 is deprecated, point your docker volume to $2\033[0m\n"
}

check_deprecated_paths() {
  declare -A deprecated_paths
  local deprecated_avatar_path="/var/www/passbolt/webroot/img/public/Avatar"
  local avatar_path="/usr/share/php/passbolt/webroot/img/public/Avatar"
  local deprecated_subscription_path="/var/www/passbolt/webroot/img/public/Avatar"
  local subscription_path="/etc/passbolt/license"
  deprecated_paths=(
    ['/var/www/passbolt/config/gpg/serverkey.asc']='/etc/passbolt/gpg/serverkey.asc'
    ['/var/www/passbolt/config/gpg/serverkey_private.asc']='/etc/passbolt/gpg/serverkey_private.asc'
  )

  if [ -z "$PASSBOLT_GPG_SERVER_KEY_PUBLIC" ] || [ -z "$PASSBOLT_GPG_SERVER_KEY_PRIVATE" ]; then
    for path in "${!deprecated_paths[@]}"
    do
      if [ -f "$path" ] && [ ! -f "${deprecated_paths[$path]}" ]; then
        ln -s "$path" "${deprecated_paths[$path]}"
        create_deprecation_message "$path" "${deprecated_paths[$path]}"
      fi
    done
  fi

  if [ -d "$deprecated_avatar_path" ] && [ ! -d "$avatar_path" ]; then
    ln -s "$deprecated_avatar_path" "$avatar_path"
    create_deprecation_message "$deprecated_avatar_path" "$avatar_path"
  fi

  if [ -f "$deprecated_subscription_path" ] && [ ! -f "$subscription_path" ]; then
    ln -s "$deprecated_subscription_path" "$subscription_path"
    create_deprecation_message "$deprecated_subscription_path" "$subscription_path"
  fi
}

check_deprecated_paths

if [ ! -f "$gpg_private_key" ] || \
   [ ! -f "$gpg_public_key" ]; then
  gpg_gen_key
  gpg_import_key
else
  gpg_import_key
fi

if [ ! -f "$ssl_key" ] && [ ! -L "$ssl_key" ] && \
   [ ! -f "$ssl_cert" ] && [ ! -L "$ssl_cert" ]; then
  gen_ssl_cert
fi

install
email_cron_job

echo -e "$deprecation_message"

exec /usr/bin/supervisord -n
