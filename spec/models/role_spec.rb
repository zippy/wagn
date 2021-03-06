require File.expand_path('../spec_helper', File.dirname(__FILE__))


describe Role, "Authenticated User" do
  before do
    @auth = Role[:auth]
  end
  
  it "should cache roles by codename" do
    Role.should_not_receive(:find_by_codename)
    Role[:auth]
  end

  it "should cache roles by id" do
    Role[@auth.id]
    Role.should_not_receive(:find)
    Role[@auth.id]
  end
end

=begin
describe User, "Anonymous User" do
  before do
    User.current_user = ::User['anon']
  end
  
  it "should ok anon role" do Wagn.role_ok?(Role['anon'].id).should be_true end
  it "should not ok auth role" do Wagn.role_ok?(Role['auth'].id).should_not be_true end
end

describe User, "Authenticated User" do
  before do
    User.current_user = ::User.find_by_login('joe_user')
  end
  it "should ok anon role" do Wagn.role_ok?(Role['anon'].id).should be_true end
  it "should ok auth role" do Wagn.role_ok?(Role['auth'].id).should be_true end
end
=end

describe User, "Admin User" do
  before do
    User.current_user = ::User[:wagbot]
  end
#  it "should ok admin role" do Wagn.role_ok?(Role['admin'].id).should be_true end
  
  it "should have correct parties" do
    User.current_user.parties.sort.should == ['administrator', "anyone", "anyone_signed_in",'wagn_bot']
  end
    
end

describe User, 'Joe User' do
  before do
    User.current_user = :joe_user
    User.cache.delete 'joe_user'
    @ju = User.current_user
    @r1 = Role.find_by_codename 'r1'
  end
  
  it "should initially have no roles" do
    @ju.roles.length.should==0
  end
  it "should immediately set new roles and return auth, anon, and the new one" do
    @ju.roles=[@r1]
    @ju.roles.length.should==1
  end
  it "should save new roles and reload correctly" do
    @ju.roles=[@r1]
    @ju = User.find_by_login 'joe_user'
    @ju.roles.length.should==1  
    @ju.parties.sort.should == ["anyone", "anyone_signed_in", 'joe_user', 'r1']
  end
  
  it "should be 'among' itself" do
    @ju.among?(['joe_user']).should == true
    @ju.among?(['faker1','joe_user','faker2']).should == true
  end
  
end
