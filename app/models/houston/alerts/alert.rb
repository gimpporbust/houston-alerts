module Houston
  module Alerts
    class Alert < ActiveRecord::Base
      self.table_name = "alerts"
      self.inheritance_column = nil
      
      belongs_to :project
      belongs_to :checked_out_by, class_name: "User"
      
      default_value_for :opened_at do; Time.now; end
      
      validates :type, :key, :summary, :url, :opened_at, presence: true
      
      before_save :update_checked_out_by, :if => :checked_out_by_email_changed?
      before_save :update_project, :if => :project_slug_changed?
      
      
      
      def self.open
        where(closed_at: nil)
      end
      
      def self.closed
        where(arel_table[:closed_at].not_eq(nil))
      end
      
      def self.without(*keys)
        where(arel_table[:key].not_in(keys.flatten))
      end
      
      def self.synchronize(type, current_alerts)
        Houston.benchmark("[alerts.synchronize] synchronize #{current_alerts.length} #{type.pluralize}") do
          current_keys = current_alerts.map { |attrs| attrs[:key] }
          existing_alerts = where(type: type, key: current_keys)
          existing_keys = existing_alerts.map(&:key)
          
          # Create current alerts that don't exist
          current_alerts.each do |attrs|
            next if existing_keys.member? attrs[:key]
            create! attrs.merge(type: type)
          end
          
          # Update existing alerts that are current
          existing_alerts.each do |existing_alert|
            current_attrs = current_alerts.detect { |attrs| attrs[:key] == existing_alert.key }
            existing_alert.attributes = current_attrs if current_attrs
            existing_alert.save if existing_alert.changed?
          end
          
          # Close alerts that aren't current
          Houston::Alerts::Alert.open
            .where(type: type)
            .without(current_keys)
            .close!
        end; nil
      end
      
      def self.close!
        update_all(closed_at: Time.now)
      end
      
      
      
    private
      
      def update_checked_out_by
        self.checked_out_by = User.with_email_address(checked_out_by_email).first
      end
      
      def update_project
        self.project = Project.find_by_slug(project_slug) if project_slug
      end
      
    end
  end
end