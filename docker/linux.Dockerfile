# The Linux build and test image: the Swift toolchain, and fonts for the text tests (Liberation has Helvetica's and Times' metrics).
FROM swift:6.4
RUN apt-get update && apt-get install -y --no-install-recommends fonts-liberation && rm -rf /var/lib/apt/lists/*
