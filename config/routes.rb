Houston::Alerts::Engine.routes.draw do
  
  get "", to: "alerts#index", as: :alerts
  get "dashboard", to: "alerts#dashboard"
  
  post "timekeeping", to: "alerts#time", as: :timekeeping
  get "thanks", to: "alerts#thanks"
  
end
