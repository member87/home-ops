# node-exporter and a Prometheus agent that remote-writes through the FRP tunnel (frps
# proxy port 9091 on loopback) to the cluster's Prometheus. The job and instance labels
# stay those of the Lightsail box, which the alert rules, dashboards and Jevil's health
# checks select on.
{
  services.prometheus.exporters.node = {
    enable = true;
    listenAddress = "127.0.0.1";
    port = 9100;
  };

  services.prometheus = {
    enable = true;
    enableAgentMode = true;
    listenAddress = "127.0.0.1";
    port = 9090;
    globalConfig.scrape_interval = "15s";
    scrapeConfigs = [
      {
        job_name = "aws-edge-node";
        static_configs = [
          {
            targets = [ "127.0.0.1:9100" ];
            labels.instance = "aws-edge";
          }
        ];
      }
      {
        job_name = "aws-edge-prometheus-agent";
        static_configs = [
          {
            targets = [ "127.0.0.1:9090" ];
            labels.instance = "aws-edge";
          }
        ];
      }
      # Which commit comin has deployed, for Jevil's "live" check.
      {
        job_name = "aws-edge-comin";
        static_configs = [
          {
            targets = [ "127.0.0.1:4243" ];
            labels.instance = "aws-edge";
          }
        ];
      }
    ];
    remoteWrite = [ { url = "http://127.0.0.1:9091/api/v1/write"; } ];
  };
}
