class Card::PermissionDenied < Wagn::PermissionDenied
  attr_reader :card
  def initialize(card)
    @card = card
    super build_message 
  end    
  
  def build_message
    "for card #{@card.name}: #{@card.errors[:permission_denied]}"
  end
end
       
  
  
module Wagn::Model::Permissions

  module ClassMethods 
    def create_ok?()
      self.new.ok? :create
    end
  end

  def ydhpt
    "#{::User.current_user.name}, You don't have permission to"
  end
  
  def destroy_with_permissions
    ok! :delete
    # FIXME this is not tested and the error will be confusing
    dependents.each do |dep| dep.ok! :delete end
    destroy_without_permissions
  end
  
  def destroy_with_permissions!
    ok! :delete
    dependents.each do |dep| dep.ok! :delete end
    destroy_without_permissions!
  end


  
  def approved?
    self.operation_approved = true    
    self.permission_errors = []

    unless updates.keys == ['comment'] # if only updating comment, next section will handle
      new_card? ? ok?(:create) : ok?(:update)
    end
    updates.each_pair do |attr,value|

      send("approve_#{attr}")
    end         
    permission_errors.each do |err|
      errors.add :permission_denied, err
    end
    operation_approved
  end
  
  # ok? and ok! are public facing methods to approve one operation at a time
  def ok?(operation)
    #warn "ok? #{operation}"
    self.operation_approved = true    
    self.permission_errors = []
    
    send("approve_#{operation}")     
    # approve_* methods set errors on the card.
    # that's what we want when doing approve? on save and checking each attribute
    # but we don't want just checking ok? to set errors. 
    # so we hack around the errors added in approve_* by clearing them here.    
    # self.errors.clear 

    operation_approved
  end  
  
  def ok!(operation)
    raise Card::PermissionDenied.new(self) unless ok?(operation);  true
  end
  
  def who_can(operation)
    permission_rule_card(operation).first.content.split(/[,\n]/).map{|i| i.to_cardname.to_key}
  end 
  
  def permission_rule_card(operation)
    opcard = rule_card(operation.to_s)
    unless opcard or ENV['MIGRATE_PERMISSIONS'] == 'true'
      errors.add :permission_denied, "No #{operation} setting card for #{name}"      
      raise Card::PermissionDenied.new(self) 
    end
    
    rcard = begin
      User.as :wagbot do
        #Rails.logger.debug "in permission_rule_card #{opcard&&opcard.name} #{operation}"
        if opcard.content == '_left' && self.junction?
          lcard = loaded_trunk || Card.fetch_or_new(cardname.trunk_name, :skip_virtual=>true, :skip_modules=>true) 
          lcard.permission_rule_card(operation).first
        else
          opcard
        end
      end
    end
    #Rails.logger.debug "permission_rule_card #{rcard&&rcard.name}, #{opcard.name.inspect}, #{opcard}, #{opcard.cardname.inspect}"
    return rcard, opcard.cardname.trunk_name.tag_name.to_s
  end
  
  protected
  def you_cant(what)
    "#{ydhpt} #{what}"
  end
      
  def deny_because(why)    
    [why].flatten.each {|err| permission_errors << err }
    self.operation_approved = false
  end

  def lets_user(operation)
    return false if operation != :read    and Wagn::Conf[:read_only]
    return true  if operation != :comment and User.always_ok?
    User.as_user.among?( who_can(operation) )
  end

  def approve_task(operation, verb=nil)
    deny_because "Currently in read-only mode" if operation != :read && Wagn::Conf[:read_only]
    deny_because you_cant("#{verb || operation} this card") unless self.lets_user( operation ) 
  end

  def approve_create
    approve_task(:create)
  end

  def approve_read
    #warn "AR #{User.always_ok?}"
    return true if User.always_ok?
    @read_rule_id ||= permission_rule_card(:read).first.id
    ok = User.as_user.read_rule_ids.member?(@read_rule_id.to_i) 
    deny_because you_cant("read this card") unless ok
  end
  
  def approve_update
    approve_task(:update)
    approve_read if operation_approved
  end
  
  def approve_delete
    approve_task(:delete)
  end

  def approve_comment
    approve_task :comment, 'comment on'
    if operation_approved
      deny_because "No comments allowed on template cards" if template?
      deny_because "No comments allowed on hard templated cards" if hard_template
    end
  end
  
  def approve_typecode
    case
    when !typename
      deny_because("No such type")
    when !new_card? && !lets_user(:create)
      deny_because you_cant("change to this type (need create permission)"  )
    end
    #NOTE: we used to check for delete permissions on previous type, but this would really need to happen before the name gets changes 
    #(hence before the tracked_attributes stuff is run)
  end

  def approve_name
  end

  def approve_content
    unless new_card?
      if tmpl = hard_template
        deny_because you_cant("change the content of this card -- it is hard templated by #{tmpl.name}")
      end
    end
  end
  
  
  public

  def set_read_rule
    return if ENV['MIGRATE_PERMISSIONS'] == 'true'
    # avoid doing this on simple content saves?
    rcard, rclass = permission_rule_card(:read)
    self.read_rule_id = rcard.id
    self.read_rule_class = rclass
    
    #find all cards with me as trunk and update their read_rule (because of *type plus right)
    # skip if name is updated because will already be resaved
    
    if !new_card? && updates.for(:typecode)
      User.as :wagbot do
        Card.search(:left=>self.name).each do |plus_card|
          plus_card = plus_card.refresh if plus_card.frozen?
          plus_card.update_read_rule
        end
      end
    end
  end
  
  def update_read_rule
    Card.record_timestamps = Card.record_userstamps = false

    rcard, rclass = permission_rule_card(:read)
    copy = self.frozen? ? self.refresh : self
    copy.update_attributes!(
      :read_rule_id => rcard.id,
      :read_rule_class => rclass
    )
    
    unless ENV['MIGRATE_PERMISSIONS'] == 'true' 
    # currently doing a brute force search for every card that may be impacted.  may want to optimize(?)
      User.as :wagbot do
        Card.search(:left=>self.name).each do |plus_card|
          if plus_card.rule(:read) == '_left'
            plus_card.update_read_rule
          end
        end
      end
    end
    Card.record_timestamps = Card.record_userstamps = true    
  rescue
    Card.record_timestamps = Card.record_userstamps = true
    raise
  end

  def update_ruled_cards
    return if ENV['MIGRATE_PERMISSIONS'] == 'true'
    if cardname.junction? && cardname.tag_name=='*read' && (@name_or_content_changed || @trash_changed)
      
      # These instance vars are messy.  should use tracked attributes' @changed variable 
      # and get rid of @name_changed, @name_or_content_changed, and @trash_changed.
      # Above should look like [:name, :content, :trash].member?( @changed.keys ).
      # To implement that, we need to make sure @changed actually tracks trash 
      # (though maybe not as a tracked_attribute for performance reasons?)
      # AND need to make sure @changed gets wiped after save (probably last in the sequence)
      
      User.cache.reset
      #Wagn.cache.reset
      Wagn::Cache.expire_card self.key #probably shouldn't be necessary, 
      # but was sometimes getting cached version when card should be in the trash.
      # could be related to other bugs?
      in_set = {}
      if !(self.trash)
        rule_classes = Wagn::Model::Pattern.pattern_subclasses.map &:key
        rule_class_index = rule_classes.index self.cardname.trunk_name.tag_name.to_s
        return 'not a proper rule card' unless rule_class_index

        #first update all cards in set that aren't governed by narrower rule
        User.as :wagbot do
          Card.fetch(cardname.trunk_name).item_cards(:limit=>0).each do |item_card|
            in_set[item_card.key] = true
            #Rails.logger.debug "rule_classes[#{rule_class_index}] #{rule_classes.inspect} This:#{item_card.read_rule_class.inspect} idx:#{rule_classes.index(item_card.read_rule_class)}"
            next if rule_classes.index(item_card.read_rule_class) < rule_class_index
            item_card.update_read_rule
          end
        end
      end

      #then find all cards with me as read_rule_id that were not just updated and regenerate their read_rules
      if !new_record?
        Card.find_all_by_read_rule_id_and_trash(self.id, false).each do |was_ruled|  #optimize with WQL / fetch?
          next if in_set[was_ruled.key]
          was_ruled.update_read_rule
        end
      end
    end
  end
  
  def self.included(base)   
    super
    base.extend(ClassMethods)
#    base.before_save.unshift Proc.new{|rec| rec.set_read_rule }
#    base.after_save.unshift  Proc.new{|rec| rec.update_ruled_cards }
#    base.alias_method_chain :save, :permissions
#    base.alias_method_chain :save!, :permissions
    base.alias_method_chain :destroy, :permissions
    base.alias_method_chain :destroy!, :permissions
    
    base.class_eval do           
      attr_accessor :operation_approved, :permission_errors
    end
  end
end
