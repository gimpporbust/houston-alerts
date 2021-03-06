module Houston
  module Alerts
    class Alert < ActiveRecord::Base
      attr_accessor :updated_by
      
      self.table_name = "alerts"
      self.inheritance_column = nil
      
      belongs_to :project
      belongs_to :checked_out_by, class_name: "User"
      
      default_value_for :opened_at do; Time.now; end
      
      default_scope { where(destroyed_at: nil).order(:deadline) }
      
      validates :type, :key, :summary, :url, :opened_at, presence: true
      validates :priority, presence: true, inclusion: {:in => %w{high urgent}}
      
      before_save :update_checked_out_by, :if => :checked_out_by_email_changed?
      before_save :update_project, :if => :project_slug_changed?
      before_save :update_deadline, :if => :opened_at_or_priority_changed?
      
      after_create do
        Houston.observer.fire "alert:create", self
        Houston.observer.fire "alert:#{type}:create", self
      end
      
      after_update do
        if checked_out_by_id_changed?
          Houston.observer.fire "alert:assign", self
          Houston.observer.fire "alert:#{type}:assign", self
        end
      end
      
      
      
      class << self
        def open
          where(closed_at: nil)
        end
        
        def closed(options={})
          if options.key?(:after)
            where(arel_table[:closed_at].gteq(options[:after]))
          else
            where(arel_table[:closed_at].not_eq(nil))
          end
        end
        
        def closed_on(date)
          where(closed_at: date.to_time.beginning_of_day..date.to_time.end_of_day)
        end
        
        def checked_out
          where(arel_table[:checked_out_by_id].not_eq(nil))
        end
        
        def checked_out_by(user)
          where(checked_out_by_id: user.id)
        end
        
        def due_before(time)
          where(arel_table[:deadline].lteq(time))
        end
        
        def without(*keys)
          where(arel_table[:key].not_in(keys.flatten))
        end
        
        def destroyed
          unscoped.where(arel_table[:destroyed_at].not_eq nil)
        end
        
        def synchronize(mode, type, alerts)
          case mode
          when :all then synchronize_all(type, alerts)
          when :open then synchronize_open(type, alerts)
          else raise NotImplementedError, "I don't know how to synchronize #{mode.inspect}"
          end
        end
        
        def synchronize_open(type, open_alerts)
          Houston.benchmark("[alerts.synchronize:open] synchronize #{open_alerts.length} #{type.pluralize}") do
            open_alerts.uniq! { |alert| alert[:key] }
            open_alerts_keys = open_alerts.map { |attrs| attrs[:key] }
            
            # Close alerts that are no longer open
            Houston::Alerts::Alert.open
              .where(type: type)
              .without(open_alerts_keys)
              .close!
            
            # Reopen alerts that were closed prematurely
            Houston::Alerts::Alert.closed
              .where(type: type)
              .where(key: open_alerts_keys)
              .reopen!
            
            # Load currently open alerts so that they may be
            # compared to the new open alerts
            existing_alerts = open.where(type: type, key: open_alerts_keys)
            existing_alerts_keys = existing_alerts.map(&:key)
            
            # Create current alerts that don't exist
            open_alerts.each do |attrs|
              next if existing_alerts_keys.member? attrs[:key]
              create! attrs.merge(type: type)
            end
            
            # Update existing alerts that are current
            existing_alerts.each do |existing_alert|
              current_attrs = open_alerts.detect { |attrs| attrs[:key] == existing_alert.key }
              existing_alert.attributes = current_attrs if current_attrs
              existing_alert.save if existing_alert.changed?
            end
          end; nil
        end
        
        def synchronize_all(type, expected_alerts)
          Houston.benchmark("[alerts.synchronize:all] synchronize #{expected_alerts.length} #{type.pluralize}") do
            expected_alerts.uniq! { |alert| alert[:key] }
            expected_alerts_keys = expected_alerts.map { |attrs| attrs[:key] }
            
            # Prune alerts that were deleted remotely
            Houston::Alerts::Alert
              .where(type: type)
              .without(expected_alerts_keys)
              .destroy!
            
            # Resurrect alerts that were deleted prematurely
            Houston::Alerts::Alert.destroyed
              .where(type: type)
              .where(key: expected_alerts_keys)
              .undestroy!
            
            # Load existing alerts so that they may be
            # compared to the new expected alerts.
            # NB: This could grow to be a large number of objects!
            existing_alerts = where(type: type, key: expected_alerts_keys)
            existing_alerts_keys = existing_alerts.map(&:key)
            
            # Create current alerts that don't exist
            expected_alerts.each do |attrs|
              next if existing_alerts_keys.member? attrs[:key]
              create! attrs.merge(type: type)
            end
            
            # Update existing alerts that are current
            existing_alerts.each do |existing_alert|
              current_attrs = expected_alerts.detect { |attrs| attrs[:key] == existing_alert.key }
              existing_alert.attributes = current_attrs if current_attrs
              existing_alert.save if existing_alert.changed?
            end
          end; nil
        end
        
        def close!
          update_all(closed_at: Time.now)
        end
        
        def reopen!
          update_all(closed_at: nil)
        end
        
        def destroy!
          update_all(destroyed_at: Time.now)
        end
        
        def undestroy!
          update_all(destroyed_at: nil)
        end
      end
      
      
      
      def opened_at_or_priority_changed?
        return true if new_record?
        opened_at_changed? or priority_changed?
      end
      
      def urgent?
        priority == "urgent"
      end
      
      def assigned?
        checked_out_by_id.present?
      end
      
      def seconds_remaining
        (deadline - Time.now).to_i
      end
      
      def summary=(value)
        value = value[0...252] + "..." if value && value.length > 255
        super
      end
      
      def on_time?(now=Time.now)
        return closed_at <= deadline if closed_at # it was closed on time
        return false if deadline < now            # it's too late for it to be closed on time
        nil                                       # it has a chance of being either true or false
      end
      
      
      
    private
      
      def update_checked_out_by
        self.checked_out_by = User.with_email_address(checked_out_by_email).first
      end
      
      def update_project
        self.project = Project.find_by_slug(project_slug) if project_slug
      end
      
      def update_deadline
        self.deadline = urgent? ? urgent_deadline : high_priority_deadline
      end
      
      def urgent_deadline
        2.hours.after(opened_at)
      end
      
      def high_priority_deadline
        if weekend?(opened_at)
          2.days.after(monday_after(opened_at))
        else
          deadline = 2.days.after(opened_at)
          deadline = 2.days.after(deadline) if weekend?(deadline)
          deadline
        end
      end
      
      def weekend?(time)
        [0, 6].member?(time.wday)
      end
      
      def monday_after(time)
        8.hours.after(1.week.after(time.beginning_of_week))
      end
      
    end
  end
end
