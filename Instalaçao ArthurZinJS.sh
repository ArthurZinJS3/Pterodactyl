#!/bin/bash

# Função para instalar dependências
install_dependencies() {
  echo "Instalando dependências..."
  sudo apt -y install software-properties-common curl apt-transport-https ca-certificates gnupg
  sudo LC_ALL=C.UTF-8 add-apt-repository -y ppa:ondrej/php
  sudo add-apt-repository ppa:redislabs/redis -y
  curl -sS https://downloads.mariadb.com/MariaDB/mariadb_repo_setup | sudo bash
  sudo apt update
  sudo apt -y install php8.1 php8.1-{cli,gd,mysql,pdo,mbstring,tokenizer,bcmath,xml,fpm,curl,zip} mariadb-server nginx tar unzip git redis-server nano
  curl -sS https://getcomposer.org/installer | sudo php -- --install-dir=/usr/local/bin --filename=composer
}

# Função para instalar o painel
install_panel() {
  echo "Instalando o painel..."

  sudo mkdir -p /var/www/pterodactyl
  cd /var/www/pterodactyl || exit

  sudo curl -Lo panel.tar.gz https://github.com/Next-Panel/Pterodactyl-BR/releases/latest/download/panel.tar.gz
  sudo tar -xzvf panel.tar.gz
  sudo chmod -R 755 storage/* bootstrap/cache/

  echo "Por favor, insira a senha para o usuário do banco de dados 'pterodactyl':"
  read -r db_password

  # Aqui estou supondo que o MySQL root não tem senha.
  # Caso contrário, você pode precisar modificar esta parte.
  sudo mysql -u root -e "CREATE USER 'pterodactyl'@'127.0.0.1' IDENTIFIED BY '$db_password'; CREATE DATABASE panel; GRANT ALL PRIVILEGES ON panel.* TO 'pterodactyl'@'127.0.0.1' WITH GRANT OPTION;"

  sudo cp .env.example .env
  sudo composer install --no-dev --optimize-autoloader
  sudo php artisan key:generate --force
  sudo php artisan p:environment:setup
  sudo php artisan p:environment:database
  sudo php artisan migrate --seed --force
  sudo php artisan p:user:make
  sudo chown -R www-data:www-data /var/www/pterodactyl/*
}


# Função para iniciar o painel
start_panel() {
  echo "Iniciando o painel..."

  # Configurando o Crontab
  echo "Configurando o cronjob..."
  (crontab -l 2>/dev/null; echo "* * * * * php /var/www/pterodactyl/artisan schedule:run >> /dev/null 2>&1") | crontab -

  # Configurando o Systemd Queue Worker
  echo "Configurando o Systemd Queue Worker..."
  sudo bash -c 'cat > /etc/systemd/system/pteroq.service << EOL
[Unit]
Description=Pterodactyl Queue Worker

[Service]
User=www-data
Group=www-data
Restart=always
ExecStart=/usr/bin/php /var/www/pterodactyl/artisan queue:work --queue=high,standard,low --sleep=3 --tries=3

[Install]
WantedBy=multi-user.target
EOL'

  # Ativando o Systemd Queue Worker e o Redis
  echo "Ativando o Systemd Queue Worker e o Redis..."
  sudo systemctl enable --now pteroq.service
  sudo systemctl enable --now redis-server

  echo "O painel foi iniciado e configurado com sucesso!"
}


# Função para configurar o SSL
configure_ssl() {
  echo "Configurando SSL..."
  echo "Informe o domínio para o qual você está instalando:"
  read -r domain_name

  apt install -y certbot python3-certbot-nginx
  certbot certonly --nginx -d "$domain_name"

  nginx_config="server {
    listen 80;
    server_name $domain_name;
    return 301 https://\$server_name\$request_uri;
  }

  server {
      listen 443 ssl http2;
      server_name $domain_name;
      
      root /var/www/pterodactyl/public;
    index index.php;

    access_log /var/log/nginx/pterodactyl.app-access.log;
    error_log  /var/log/nginx/pterodactyl.app-error.log error;

    # allow larger file uploads and longer script runtimes
    client_max_body_size 100m;
    client_body_timeout 120s;

    sendfile off;

    # SSL Configuration
    ssl_certificate /etc/letsencrypt/live/$domain_name/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$domain_name/privkey.pem;
    ssl_session_cache shared:SSL:10m;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers "ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384";
    ssl_prefer_server_ciphers on;

    add_header X-Content-Type-Options nosniff;
    add_header X-XSS-Protection "1; mode=block";
    add_header X-Robots-Tag none;
    add_header Content-Security-Policy "frame-ancestors 'self'";
    add_header X-Frame-Options DENY;
    add_header Referrer-Policy same-origin;

    location / {
        try_files $uri $uri/ /index.php?$query_string;
    }

    location ~ \.php$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)$;
        fastcgi_pass unix:/run/php/php8.1-fpm.sock;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param PHP_VALUE "upload_max_filesize = 100M \n post_max_size=100M";
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        fastcgi_param HTTP_PROXY "";
        fastcgi_intercept_errors off;
        fastcgi_buffer_size 16k;
        fastcgi_buffers 4 16k;
        fastcgi_connect_timeout 300;
        fastcgi_send_timeout 300;
        fastcgi_read_timeout 300;
        include /etc/nginx/fastcgi_params;
    }

    location ~ /\.ht {
        deny all;
    }
  }
  }"

  echo "$nginx_config" > /etc/nginx/sites-available/pterodactyl.conf
  ln -s /etc/nginx/sites-available/pterodactyl.conf /etc/nginx/sites-enabled/
  nginx -t
  systemctl restart nginx
}

# Instalar dependências antes de mostrar o menu
install_dependencies

# Menu
while true; do
  echo "Escolha uma opção:"
  echo "0) Instalar o painel"
  echo "1) Iniciar o painel"
  echo "2) Configurar SSL"
  echo "3) Sair"
  
  read -r option

  case "$option" in
    0)
      install_panel
      ;;
    1)
      start_panel
      ;;
    2)
      configure_ssl
      ;;
    3)
      echo "Saindo..."
      exit 0
      ;;
    *)
      echo "Opção inválida"
      ;;
  esac
done
