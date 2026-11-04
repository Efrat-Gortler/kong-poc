# Built in-cluster by an OpenShift BuildConfig (charts/blocking-service), context = this directory.
FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src
COPY BlockingService.sln ./
COPY src/BlockingService/BlockingService.csproj src/BlockingService/
COPY tests/BlockingService.Tests/BlockingService.Tests.csproj tests/BlockingService.Tests/
RUN dotnet restore
COPY . .
# Unit tests gate the image: a failing test fails the build.
RUN dotnet test tests/BlockingService.Tests -c Release --no-restore --logger "console;verbosity=normal"
RUN dotnet publish src/BlockingService -c Release --no-restore -o /app

FROM mcr.microsoft.com/dotnet/aspnet:10.0
WORKDIR /app
COPY --from=build /app .
ENV ASPNETCORE_HTTP_PORTS=8080 \
    DOTNET_gcServer=0
EXPOSE 8080
# The aspnet image runs as a non-root user; OpenShift assigns its own UID anyway.
ENTRYPOINT ["dotnet", "BlockingService.dll"]
