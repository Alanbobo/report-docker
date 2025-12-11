#!/bin/bash
set -euo pipefail

###############################################
# JimuReport ARM 自动部署脚本（从 GitHub 拉取）
###############################################

GIT_URL="https://github.com/jeecgboot/jimureport.git"
SRC_ROOT="./jimureport-src"
EXAMPLE_DIR="$SRC_ROOT/jimureport-example"
JAR_DIR="./jimureport/jar"
APP_JAR="$JAR_DIR/app.jar"

MYSQL_IMAGE="arm64v8/mysql:8"
JDK_IMAGE="eclipse-temurin:17-jdk"

green(){ echo -e "\033[32m$1\033[0m"; }
yellow(){ echo -e "\033[33m$1\033[0m"; }
red(){ echo -e "\033[31m$1\033[0m"; }

ACTION=${1:-up}

###############################################################
# 新增函数：检查并选择镜像
check_and_select_image() {
  local mysql_image="mysql:8"
  local jdk_image="eclipse-temurin:17-jdk"
  
  # 检查机器架构
  local arch=$(uname -m)
  yellow "🔍 检测到系统架构: $arch"
  
  # 检查本地镜像是否存在
  if [ "$arch" = "arm64" ] || [ "$arch" = "aarch64" ]; then
    # ARM 架构
    if docker image inspect arm64v8/mysql:8 >/dev/null 2>&1; then
      MYSQL_IMAGE="arm64v8/mysql:8"
      green "✅ 使用本地已有的 ARM MySQL 镜像"
    elif docker image inspect mysql:8 >/dev/null 2>&1; then
      MYSQL_IMAGE="mysql:8"
      yellow "⚠ 使用已有的通用 MySQL 镜像（非 ARM 专用）"
    else
      yellow "📥 MySQL 镜像不存在，将尝试拉取 ARM 版本"
      MYSQL_IMAGE="arm64v8/mysql:8"
    fi
    
    if docker image inspect arm64v8/openjdk:17-jdk >/dev/null 2>&1; then
      JDK_IMAGE="arm64v8/openjdk:17-jdk"
      green "✅ 使用本地已有的 ARM OpenJDK 镜像"
    elif docker image inspect arm64v8/eclipse-temurin:17-jdk >/dev/null 2>&1; then
      JDK_IMAGE="arm64v8/eclipse-temurin:17-jdk"
      green "✅ 使用本地已有的 ARM Temurin 镜像"
    elif docker image inspect eclipse-temurin:17-jdk >/dev/null 2>&1; then
      JDK_IMAGE="eclipse-temurin:17-jdk"
      yellow "⚠ 使用已有的通用 JDK 镜像（非 ARM 专用）"
    else
      # 尝试查找可用的 ARM JDK 镜像
      yellow "🔍 搜索可用的 JDK 镜像..."
      if docker image ls | grep -q "openjdk.*17.*jdk"; then
        JDK_IMAGE=$(docker image ls | grep "openjdk.*17.*jdk" | head -1 | awk '{print $1":"$2}')
        green "✅ 使用现有 JDK 镜像: $JDK_IMAGE"
      else
        yellow "📥 JDK 镜像不存在，将尝试拉取 ARM 版本"
        JDK_IMAGE="eclipse-temurin:17-jdk"
      fi
    fi
  else
    # x86_64 或其他架构
    if docker image inspect mysql:8 >/dev/null 2>&1; then
      MYSQL_IMAGE="mysql:8"
      green "✅ 使用本地已有的 MySQL 镜像"
    else
      yellow "📥 MySQL 镜像不存在，将尝试拉取"
      MYSQL_IMAGE="mysql:8"
    fi
    
    if docker image inspect eclipse-temurin:17-jdk >/dev/null 2>&1; then
      JDK_IMAGE="eclipse-temurin:17-jdk"
      green "✅ 使用本地已有的 JDK 镜像"
    elif docker image inspect openjdk:17-jdk >/dev/null 2>&1; then
      JDK_IMAGE="openjdk:17-jdk"
      green "✅ 使用本地已有的 OpenJDK 镜像"
    else
      yellow "📥 JDK 镜像不存在，将尝试拉取"
      JDK_IMAGE="eclipse-temurin:17-jdk"
    fi
  fi
  
  green "📦 最终选择的镜像:"
  green "   MySQL: $MYSQL_IMAGE"
  green "   JDK: $JDK_IMAGE"
  
  # 导出为环境变量，供后续使用
  export MYSQL_IMAGE JDK_IMAGE
}

###############################################################
check_env(){
  command -v docker >/dev/null || { red "❌ 未安装 Docker"; exit 1; }
  command -v git >/dev/null || { red "❌ 未安装 Git"; exit 1; }
  command -v mvn >/dev/null && return

  yellow "⚠ 未检测到 Maven，正在安装（macOS）..."
  if command -v brew >/dev/null; then
     brew install maven
  else
     red "❌ 未检测到 brew，请手动安装 Maven"
     exit 1
  fi
}

###############################################################
create_structure(){
  for d in jimureport-mysql jimureport "$JAR_DIR" data/mysql
  do
    [ -d "$d" ] || mkdir -p "$d"
  done
}

###############################################################
clone_code(){
  if [ ! -d "$SRC_ROOT" ]; then
    yellow "⬇️ GitHub 拉取代码..."
    git clone --depth 1 "$GIT_URL" "$SRC_ROOT"
  else
    green "✅ $SRC_ROOT 已存在，跳过拉取代码"
  fi
}

###############################################################
maven_build() {
  yellow "🔧 Maven 编译 jimureport-example..."
  (cd "$EXAMPLE_DIR" && mvn -DskipTests clean package)

  yellow "🔎 查找最终可执行 Jar..."

  # 只查找 target 目录下的可执行 jar
  jar_file=$(find "$EXAMPLE_DIR" -type f -path "*/target/*.jar" \
              ! -name "*sources*" ! -name "*javadoc*" \
              -print0 | sort -z | head -zn1 | tr -d '\0')

  if [ -z "$jar_file" ]; then
    red "❌ 没找到可执行 jar"
    exit 1
  fi

  green "✔ 找到 jar：$jar_file"

  # 覆盖 app.jar
  cp -f "$jar_file" "$APP_JAR"
  green "✔ 已复制到：$APP_JAR"
}


###############################################################
create_dockerfiles(){
  # 根据选择的镜像创建 Dockerfile
  green "📄 创建 Dockerfile (使用镜像: $JDK_IMAGE)"
  
  # MySQL Dockerfile
  cat > jimureport-mysql/Dockerfile <<EOF
FROM $MYSQL_IMAGE
ENV LANG C.UTF-8
EOF

  # JDK Dockerfile
  cat > jimureport/Dockerfile <<EOF
FROM $JDK_IMAGE

WORKDIR /jimureport
COPY jar/app.jar /jimureport/app.jar

EXPOSE 8085
ENTRYPOINT ["java","-jar","/jimureport/app.jar"]
EOF
}

###############################################################
create_compose(){
cat > docker-compose.yml <<EOF
version: '3.8'
services:

  jimureport-mysql:
    build:
      context: ./jimureport-mysql
    container_name: jimureport-mysql
    restart: always
    environment:
      MYSQL_ROOT_PASSWORD: root
    ports:
      - "3306:3306"
    volumes:
      - ./data/mysql:/var/lib/mysql

  jimureport:
    build:
      context: ./jimureport
    container_name: jimureport
    restart: always
    depends_on:
      - jimureport-mysql
    ports:
      - "8085:8085"
EOF
}

###############################################################
build_and_run(){
  yellow "🐳 检查镜像是否存在..."
  
  # 检查 MySQL 镜像是否存在
  if ! docker image inspect $MYSQL_IMAGE >/dev/null 2>&1; then
    yellow "📥 拉取 MySQL 镜像: $MYSQL_IMAGE"
    docker pull $MYSQL_IMAGE
  fi
  
  # 检查 JDK 镜像是否存在
  if ! docker image inspect $JDK_IMAGE >/dev/null 2>&1; then
    yellow "📥 拉取 JDK 镜像: $JDK_IMAGE"
    docker pull $JDK_IMAGE
  fi
  
  yellow "🔨 构建应用镜像..."
  docker compose build --pull=false

  yellow "▶ 启动服务..."
  docker compose up -d

  green "🎉 JimuReport 启动成功！"
  echo ""
  green "访问地址：http://localhost:8085/jmreport/list"
  green "默认账号：admin   密码：123456"
  echo ""
  green "容器信息:"
  docker compose ps
}

###############################################################
do_up(){
  check_env
  create_structure
  clone_code
  maven_build
  check_and_select_image  # 新增：检查并选择镜像
  create_dockerfiles
  create_compose
  build_and_run
}

###############################################################
do_down(){
  docker compose down
}

###############################################################
do_restart(){
  do_down
  do_up
}

###############################################################
do_logs(){
  docker compose logs -f
}

###############################################################
do_status(){
  docker compose ps
  echo ""
  echo "本地镜像:"
  docker image ls | grep -E "mysql|openjdk|temurin" | head -10
}

###############################################################
do_clean(){
  yellow "🧹 清理构建文件..."
  read -p "是否清理所有临时文件？(包括源码、jar包) [y/N]: " confirm
  if [[ "$confirm" =~ ^[Yy]$ ]]; then
    rm -rf "$SRC_ROOT" "$JAR_DIR/app.jar" jimureport-mysql/Dockerfile jimureport/Dockerfile docker-compose.yml
    green "✅ 已清理"
  fi
}

###############################################################
case "$ACTION" in
  up) do_up ;;
  down) do_down ;;
  restart) do_restart ;;
  logs) do_logs ;;
  status) do_status ;;
  clean) do_clean ;;
  *)
    echo "用法： ./deploy_arm.sh {up|down|restart|logs|status|clean}"
    echo ""
    echo "  up       启动服务（默认）"
    echo "  down     停止服务"
    echo "  restart  重启服务"
    echo "  logs     查看日志"
    echo "  status   查看状态"
    echo "  clean    清理临时文件"
    exit 1;;
esac