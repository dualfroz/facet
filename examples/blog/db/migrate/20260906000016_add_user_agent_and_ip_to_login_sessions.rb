class AddUserAgentAndIpToLoginSessions < Facet::Orm::Migration
  def up
    add_column :login_sessions, :user_agent, default: nil
    add_column :login_sessions, :ip_address, default: nil
  end

  def down
    remove_column :login_sessions, :user_agent
    remove_column :login_sessions, :ip_address
  end
end
