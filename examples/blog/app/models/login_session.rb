class LoginSession < Prism::Orm::Model
  belongs_to :user

  # The persistent-login cookie's actual credential - never rendered
  # anywhere (see LoginSessionsController#index), and hidden from
  # serialization so a stray as_json never leaks it either.
  has_secure_token :token
  hide_from_json :token
end
