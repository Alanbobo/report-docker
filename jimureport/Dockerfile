FROM eclipse-temurin:17-jdk

WORKDIR /jimureport
COPY jar/app.jar /jimureport/app.jar

EXPOSE 8085
ENTRYPOINT ["java","-jar","/jimureport/app.jar"]
