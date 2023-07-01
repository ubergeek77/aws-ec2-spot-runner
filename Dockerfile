FROM amazon/aws-cli
RUN yum install -y jq util-linux
RUN mkdir -p /app
WORKDIR /app
COPY entrypoint.sh /entrypoint.sh
COPY spot-instance-launch-template.json /app/spot-instance-launch-template.json
COPY user-data-template.sh /app/user-data-template.sh
ENTRYPOINT ["/entrypoint.sh"]
