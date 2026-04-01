FROM nginx:alpine
COPY school-demo.html /usr/share/nginx/html/index.html
COPY default.conf /etc/nginx/conf.d/default.conf
EXPOSE 80
CMD ["nginx", "-g", "daemon off;"]
