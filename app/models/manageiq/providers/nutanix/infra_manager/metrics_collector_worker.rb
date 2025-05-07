class ManageIQ::Providers::Nutanix::InfraManager::MetricsCollectorWorker < ManageIQ::Providers::BaseManager::MetricsCollectorWorker
  self.default_queue_name = "nutanix"

  def friendly_name
    @friendly_name ||= "C&U Metrics Collector for ManageIQ::Providers::Nutanix"
  end
end
