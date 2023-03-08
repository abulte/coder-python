ARG PYTHON_VERSION=latest
FROM python:${PYTHON_VERSION}

RUN apt-get update \
	&& apt-get install -y \
	curl \
	git \
	sudo \
	vim \
	wget \
	postgresql-13 \
	&& rm -rf /var/lib/apt/lists/*

ARG USER=coder
RUN useradd --groups sudo --no-create-home --shell /bin/bash ${USER} \
	&& echo "${USER} ALL=(ALL) NOPASSWD:ALL" >/etc/sudoers.d/${USER} \
	&& chmod 0440 /etc/sudoers.d/${USER}
USER ${USER}
WORKDIR /home/${USER}
