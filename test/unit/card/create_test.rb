require File.expand_path('../../test_helper', File.dirname(__FILE__))
class Card::CreateTest < ActiveSupport::TestCase
  
  def setup
    super
    setup_default_user
  end
  def test_fetch_or_create_when_present
    Card.create!(:name=>"Carrots")
    assert_no_difference Card, :count do 
      assert_instance_of Card, Card.fetch_or_create("Carrots")
    end
  end  
  
  def test_simple
    assert_difference Card, :count do 
      assert_instance_of Card, Card.create(:name=>"Boo!")
      assert Card.find_by_name("Boo!")
    end
  end
  
  
  def test_fetch_or_create_when_not_present
    assert_difference Card, :count do 
      assert_instance_of Card, Card.fetch_or_create("Tomatoes")
    end
  end
  
  def test_create_junction
    assert_difference Card, :count, 3 do
      assert_instance_of Card, Card.create(:name=>"Peach+Pear", :content=>"juicy")
    end
    assert_instance_of Card, Card.find_by_name("Peach")
    assert_instance_of Card, Card.find_by_name("Pear")
    assert_equal "juicy", Card.find_by_name("Peach+Pear").content
  end
end

