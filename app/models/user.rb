# -*- encoding : utf-8 -*-
require 'digest/sha1'

class User < ActiveRecord::Base
  #FIXME: THIS WHOLE MODEL SHOULD BE CALLED ACCOUNT
  
  # Virtual attribute for the unencrypted password
  attr_accessor :password, :name
  cattr_accessor :current_user, :as_user, :cache
  
  has_and_belongs_to_many :roles
  belongs_to :invite_sender, :class_name=>'User', :foreign_key=>'invite_sender_id'
  has_many :invite_recipients, :class_name=>'User', :foreign_key=>'invite_sender_id'

  acts_as_card_extension
   
  validates_presence_of     :email, :if => :email_required?
  validates_format_of       :email, :with => /^([^@\s]+)@((?:[-a-z0-9]+\.)+[a-z]{2,})$/i  , :if => :email_required?
  validates_length_of       :email, :within => 3..100,   :if => :email_required?
  validates_uniqueness_of   :email, :scope=>:login,      :if => :email_required?  
  validates_presence_of     :password,                   :if => :password_required?
  validates_presence_of     :password_confirmation,      :if => :password_required?
  validates_length_of       :password, :within => 5..40, :if => :password_required?
  validates_confirmation_of :password,                   :if => :password_required?
  validates_presence_of     :invite_sender,              :if => :active?
#  validates_uniqueness_of   :salt, :allow_nil => true
  
  before_validation :downcase_email!
  before_save :encrypt_password
  after_save :reset_instance_cache
  


  
  class << self
    def current_user
      @@current_user ||= User[:anon]  
    end

    def current_user=(user)
      @@as_user = nil
      @@current_user = user.class==User ? User[user.id] : User[user]
    end
   
    def inspect() "#{@@current_user&&@@current_user.login}:#{as_user&&as_user.login}" end

    def as(given_user)
      tmp_user = @@as_user
      @@as_user = given_user.class==User ? User[given_user.id] : User[given_user]
      self.current_user = @@as_user if @@current_user.nil?
      
      if block_given?
        value = yield
        @@as_user = tmp_user
        return value
      else
        #fail "BLOCK REQUIRED with User#as"
      end
    end
    
    def as_user
      @@as_user || self.current_user
    end
      

    # FIXME: args=params.  should be less coupled..
    def create_with_card(user_args, card_args, email_args={})
      @card = (Hash===card_args ? Card.new({'typecode'=>'User'}.merge(card_args)) : card_args) 
      @user = User.new({:invite_sender=>User.current_user, :status=>'active'}.merge(user_args))
      @user.generate_password if @user.password.blank?
      @user.save_with_card(@card)
      begin
        @user.send_account_info(email_args) if @user.errors.empty? && !email_args.empty?
      end
      [@user, @card]
    end

    # Authenticates a user by their login name and unencrypted password.  Returns the user or nil.
    def authenticate(email, password)
      u = self.find_by_email(email.strip.downcase)
      u && u.authenticated?(password.strip) ? u : nil
    end

    # Encrypts some data with the salt.
    def encrypt(password, salt)
      Digest::SHA1.hexdigest("#{salt}--#{password}--")
    end    
    
    def [](key)
      #Rails.logger.info "Looking up USER[ #{key}]"
      self.cache ? self.cache.read(key.to_s) ||
        self.cache.write(key.to_s, without_cache(key)) : without_cache(key)
    end

    def without_cache(key)
      usr = Integer===key ? find(key) : find_by_login(key.to_s)
      if usr #preload to be sure these get cached.
        usr.card
        usr.read_rule_ids unless usr.login=='wagbot'
      end
      usr
    end
    
    def logged_in?
      !(current_user.nil? || current_user.login=='anon')
    end

    def no_logins?
      c = self.cache
      !c.read('no_logins').nil? ? c.read('no_logins') : c.write('no_logins', (User.count < 3))
    end

    def always_ok?
      return false unless usr = as_user
      return true if usr.login == 'wagbot' #cannot disable

      always = User.cache.read('ALWAYS') || {}
      if always[usr.id].nil?
        always = always.dup if always.frozen?
        aok=false; usr.all_roles.each{|r| aok=true if r.admin?}
        always[usr.id] = aok
        User.cache.write 'ALWAYS', always
      end
      always[usr.id]
    end
    # PERMISSIONS
    
    def ok?(task)
      #warn "ok?(#{task}), #{always_ok?}"
      task = task.to_s
      return false if task != 'read' and Wagn::Conf[:read_only]
      return true  if always_ok?
      ok_hash.key? task
    end

    def ok!(task)
      if !ok?(task)
        #FIXME -- needs better error message handling
        raise Wagn::PermissionDenied.new(self.new)
      end
    end
    
  protected
    # FIXME stick this in session? cache it somehow??
    def ok_hash
      usr = User.as_user
      ok_hash = User.cache.read('OK') || {}
      if ok_hash[usr.id].nil?
        ok_hash = ok_hash.dup if ok_hash.frozen?
        ok_hash[usr.id] = begin
          ok = {}
          ok[:role_ids] = {}
          usr.all_roles.each do |role|
            ok[:role_ids][role.id] = true
            role.task_list.each { |t| ok[t] = 1 }
          end
          ok
        end || false
        User.cache.write 'OK', ok_hash
      end
      ok_hash[usr.id]
    end
    

  end 

#~~~~~~~ Instance

  def reset_instance_cache
    self.class.cache.write(id.to_s, nil)
    self.class.cache.write(login, nil) if login
  end

  def among? test_parties
    #Rails.logger.info "among called.  user = #{self.login}, parties = #{parties.inspect}, test_parties = #{test_parties.inspect}"
    parties.each do |party|
      return true if test_parties.member? party
    end
    false
  end

  def parties
    @parties ||= [self,all_roles].flatten.map{|p| p.card.key }
  end
  
  def read_rule_ids
    return [] if self.login=='wagbot'  # avoids infinite loop
    @read_rule_ids ||= begin
      party_keys = ['in'] + parties
      self.class.as(:wagbot) do
        Card.search(:right=>'*read', :refer_to=>{:key=>party_keys}, :return=>:id).map &:to_i
      end
    end
    @read_rule_ids
  end
  
  def save_with_card(c)
    #Rails.logger.info "save with card #{card.inspect}, #{self.inspect}"
    User.transaction do
      save
      if !errors.any?
        c = c.refresh if c.frozen?
        c.extension = self
        c.save
        if c.errors.any?
          c.errors.each do |key,err|
            next if key.to_s.downcase=='extension'
            self.errors.add key,err
          end
          destroy
        end
      end
    end
  end
      
  def accept(email_args)
    User.as :wagbot do #what permissions does approver lack?  Should we check for them?
      c = card
      c = c.refresh if c.frozen?
      c.typecode = 'User'  # change from Invite Request -> User
      self.status='active'
      self.invite_sender = ::User.current_user
      generate_password
      save_with_card(c)
    end
    #card.save #hack to make it so last editor is current user.
    self.send_account_info(email_args) if self.errors.empty?
  end

  def send_account_info(args)
    #return if args[:no_email]
    raise(Wagn::Oops, "subject is required") unless (args[:subject])
    raise(Wagn::Oops, "message is required") unless (args[:message])
    begin
      message = Mailer.account_info self, args[:subject], args[:message]
      message.deliver
    rescue Exception=>e
      warn "ACCOUNT INFO DELIVERY FAILED: \n #{args.inspect}\n   #{e.message}, #{e.backtrace*"\n"}"
    end
  end  

  def all_roles
    @all_roles ||= (login=='anon' ? [Role[:anon]] : 
      roles(force_reload=true) + [Role[:anon], Role[:auth]])
  end  
  

  def active?
    status=='active'
  end
  def blocked?
    status=='blocked'
  end
  def built_in?
    status=='system'
  end
  def pending?
    status=='pending'
  end

  # blocked methods for legacy boolean status
  def blocked=(block)
    if block != '0'
      self.status = 'blocked'
    elsif !built_in?
      self.status = 'active'
    end
  end

  def anonymous?
    login == 'anon'
  end

  def authenticated?(password) 
    crypted_password == encrypt(password) and active?      
  end

  def generate_password
    pw=''; 9.times { pw << ['A'..'Z','a'..'z','0'..'9'].map{|r| r.to_a}.flatten[rand*61] }
    self.password = pw 
    self.password_confirmation = self.password
  end

  def to_s
    "#<#{self.class.name}:#{login.blank? ? email : login}}>"
  end

  def mocha_inspect
    to_s
  end
   
  #before validation
  def downcase_email!
    if e = self.email and e != e.downcase
      self.email=e.downcase
    end
  end 
   
  protected
  # Encrypts the password with the user salt
  def encrypt(password)
    self.class.encrypt(password, salt)
  end

  # before save
  def encrypt_password
    return if password.blank?
    self.salt = Digest::SHA1.hexdigest("--#{Time.now.to_s}--#{login}--") if new_record?
    self.crypted_password = encrypt(password)
  end

  def email_required?
    !built_in?
  end

  def password_required?
     !built_in? && 
     !pending?  && 
     #not_openid? && 
     (crypted_password.blank? or not password.blank?)
  end
 
#  def not_openid?
#    identity_url.blank?
#  end

end

