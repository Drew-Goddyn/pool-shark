from pycookiecheat import chrome_cookies
import requests

try:
  print(chrome_cookies('https://ca.apm.activecommunities.com/')["vancouver_JSESSIONID"])
except:
  print("")
